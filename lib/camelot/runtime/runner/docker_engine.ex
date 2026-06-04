defmodule Camelot.Runtime.Runner.DockerEngine do
  @moduledoc """
  Runner backend that creates one-shot containers via
  the local Docker Engine HTTP API. Useful for
  single-node deployments and for testing the
  containerised path on a dev VM without Swarm.

  Mounts the user's profile volume at `/home/agent`,
  passes credentials via env vars (Swarm secrets aren't
  available outside Swarm), and removes the container on
  exit.
  """
  @behaviour Camelot.Runtime.Runner

  use GenServer, restart: :temporary

  alias Camelot.Runtime.Runner
  alias Camelot.Runtime.Runner.DockerApi
  alias Camelot.Runtime.Runner.Spec

  require Logger

  defstruct [
    :owner,
    :container_id,
    :session_id,
    :log_task,
    :wait_task,
    spec: nil
  ]

  @impl Runner
  def start(%Spec{} = spec), do: GenServer.start(__MODULE__, spec)

  @impl Runner
  def stop(handle) when is_pid(handle) do
    if Process.alive?(handle), do: GenServer.cast(handle, :stop)
    :ok
  end

  # --- GenServer ---

  @impl GenServer
  def init(%Spec{} = spec) do
    case create_and_start(spec) do
      {:ok, container_id} ->
        state = %__MODULE__{
          owner: spec.owner_pid,
          container_id: container_id,
          session_id: spec.session_id,
          spec: spec
        }

        {:ok, kick_off_streams(state)}

      {:error, reason} ->
        Logger.error("DockerEngine start failed: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_cast(:stop, state) do
    remove_container(state.container_id)
    {:stop, :normal, state}
  end

  @impl GenServer
  def handle_info({:log_chunk, bytes}, state) do
    send(state.owner, {:runner_data, self(), bytes})
    {:noreply, state}
  end

  def handle_info({:log_done, _ref}, state), do: {:noreply, state}

  def handle_info({:exit_code, code}, state) do
    send(state.owner, {:runner_exit, self(), code})
    remove_container(state.container_id)
    {:stop, :normal, state}
  end

  def handle_info({ref, _}, state) when is_reference(ref), do: {:noreply, state}
  def handle_info({:DOWN, _, _, _, _}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  # --- Lifecycle ---

  defp create_and_start(%Spec{} = spec) do
    name = spec.service_name || Spec.service_name(spec.session_id)

    with {:ok, id} <- create_container(spec, name),
         :ok <- start_container(id) do
      {:ok, id}
    end
  end

  defp create_container(%Spec{} = spec, name) do
    payload = container_create_payload(spec)

    case Req.post(DockerApi.request(), url: "/containers/create", params: [name: name], json: payload) do
      {:ok, %Req.Response{status: status, body: %{"Id" => id}}} when status in 200..299 ->
        {:ok, id}

      {:ok, resp} ->
        {:error, {:create_failed, resp.status, resp.body}}

      {:error, _} = err ->
        err
    end
  end

  defp start_container(id) do
    case Req.post(DockerApi.request(), url: "/containers/#{id}/start") do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      {:ok, resp} -> {:error, {:start_failed, resp.status, resp.body}}
      {:error, _} = err -> err
    end
  end

  defp remove_container(nil), do: :ok

  defp remove_container(id) do
    Req.delete(DockerApi.request(), url: "/containers/#{id}", params: [force: true, v: true])
    :ok
  rescue
    _ -> :ok
  end

  defp container_create_payload(%Spec{} = spec) do
    reject_nil(%{
      "Image" => spec.image || "alpine:latest",
      "Cmd" => spec.argv,
      "Env" => env_pairs(spec),
      "WorkingDir" => spec.cwd,
      "HostConfig" => %{"AutoRemove" => false, "Binds" => binds(spec)}
    })
  end

  defp env_pairs(%Spec{} = spec) do
    base = Enum.map(spec.env, fn {k, v} -> "#{k}=#{v}" end)
    secret_env = Enum.flat_map(spec.secrets, &secret_to_env/1)
    extras = bootstrap_env(spec) ++ repo_env(spec) ++ mcp_env(spec)

    base ++ secret_env ++ extras
  end

  # Map each credential kind to whatever env var the target CLI tool
  # natively reads. Kinds without a canonical mapping fall through as
  # CAMELOT_SECRET_<KIND> for the image's entrypoint to materialise.
  defp secret_to_env(%{kind: :claude_api_key, value: v}), do: ["ANTHROPIC_API_KEY=#{v}"]
  defp secret_to_env(%{kind: :openai_api_key, value: v}), do: ["OPENAI_API_KEY=#{v}"]
  defp secret_to_env(%{kind: :codex_api_key, value: v}), do: ["OPENAI_API_KEY=#{v}"]

  defp secret_to_env(%{kind: kind, value: v}) when kind in [:github_pat, :github_oauth],
    do: ["GH_TOKEN=#{v}", "GITHUB_TOKEN=#{v}"]

  defp secret_to_env(%{kind: kind, value: v}) do
    ["CAMELOT_SECRET_#{String.upcase(Atom.to_string(kind))}=#{v}"]
  end

  defp bootstrap_env(%Spec{bootstrap?: true}), do: ["BOOTSTRAP=1"]
  defp bootstrap_env(_), do: []

  defp repo_env(%Spec{repo_url: nil}), do: []

  defp repo_env(%Spec{repo_url: url, repo_branch: branch}) do
    ["REPO_URL=#{url}"] ++ if(branch, do: ["REPO_BRANCH=#{branch}"], else: [])
  end

  defp mcp_env(%Spec{mcp_config_json: nil}), do: []
  defp mcp_env(%Spec{mcp_config_json: json}), do: ["PROJECT_MCP_CONFIG_JSON=#{json}"]

  defp binds(%Spec{profile_volume: nil}), do: []
  defp binds(%Spec{profile_volume: vol}), do: ["#{vol}:/home/agent:rw"]

  defp reject_nil(map) when is_map(map) do
    map
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new(fn {k, v} -> {k, reject_nil(v)} end)
  end

  defp reject_nil(other), do: other

  # --- Streaming + waiting ---

  defp kick_off_streams(%__MODULE__{} = state) do
    parent = self()
    id = state.container_id

    log_task =
      Task.async(fn ->
        stream_logs(id, parent)
      end)

    wait_task =
      Task.async(fn ->
        code = wait_container(id)
        send(parent, {:exit_code, code})
      end)

    %{state | log_task: log_task, wait_task: wait_task}
  end

  defp stream_logs(id, parent) do
    # When Tty: false on the container, Docker's /logs endpoint
    # returns a multiplexed stream: each chunk is one or more frames
    # of the shape <stream_type:1, _rsvd:3, payload_size:4, payload:N>.
    # We run a small demuxer process to pull out the payload bytes
    # (stdout + stderr) and forward them to the runner GenServer.
    demuxer = spawn_link(fn -> demux_loop(parent, <<>>) end)

    Req.get(DockerApi.request(),
      url: "/containers/#{id}/logs",
      params: [stdout: true, stderr: true, follow: true, timestamps: false],
      receive_timeout: :infinity,
      into: fn {:data, chunk}, acc ->
        send(demuxer, {:chunk, chunk})
        {:cont, acc}
      end
    )

    send(demuxer, :done)
    send(parent, {:log_done, make_ref()})
  rescue
    e ->
      Logger.warning("DockerEngine log stream crashed: #{inspect(e)}")
      send(parent, {:log_done, make_ref()})
  end

  defp demux_loop(parent, buffer) do
    receive do
      {:chunk, chunk} ->
        new_buffer = demux_frames(buffer <> chunk, parent)
        demux_loop(parent, new_buffer)

      :done ->
        :ok
    end
  end

  # Recursively peel off full frames; return any trailing partial
  # bytes so the next chunk can complete them.
  defp demux_frames(<<stream::8, _::24, size::32-big, rest::binary>>, parent) when byte_size(rest) >= size do
    <<payload::binary-size(size), tail::binary>> = rest
    if stream in [1, 2], do: send(parent, {:log_chunk, payload})
    demux_frames(tail, parent)
  end

  defp demux_frames(buffer, _parent), do: buffer

  defp wait_container(id) do
    case Req.post(DockerApi.request(), url: "/containers/#{id}/wait", receive_timeout: :infinity) do
      {:ok, %Req.Response{status: 200, body: %{"StatusCode" => code}}} when is_integer(code) ->
        code

      {:ok, _} ->
        1

      {:error, reason} ->
        Logger.warning("DockerEngine wait failed: #{inspect(reason)}")
        1
    end
  end
end
