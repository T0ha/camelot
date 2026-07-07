defmodule Camelot.Runtime.Runner.DockerEngine.ExecSession do
  @moduledoc """
  Per-session GenServer returned by
  `Camelot.Runtime.Runner.DockerEngine.start/1`.

  Ensures a `TaskContainer` exists for the spec's
  `task_id` and runs the agent CLI via
  `POST /containers/<id>/exec`. Streams the multiplexed
  stdout/stderr back to `spec.owner_pid` using the same
  message protocol as the Swarm backend.
  """
  use GenServer, restart: :temporary

  alias Camelot.Runtime.Runner.DockerApi
  alias Camelot.Runtime.Runner.DockerEngine.TaskContainer
  alias Camelot.Runtime.Runner.DockerStreamDemux
  alias Camelot.Runtime.Runner.Spec

  require Logger

  # Polling intervals only — no wall-clock deadlines. Container
  # setup (pull, clone, asdf install) and agent runtime can each
  # legitimately take many minutes; bounding either with a timeout
  # would just convert a slow-but-correct dispatch into a spurious
  # failure. Real upstream failures break the loop via {:error, _}.
  @ready_poll_ms 500
  @exit_poll_ms 1_000

  defstruct [
    :owner,
    :session_id,
    :task_id,
    :container_id,
    :exec_id,
    :stream_task,
    :poll_task,
    spec: nil
  ]

  @spec start(Spec.t()) :: {:ok, pid()} | {:error, term()}
  def start(%Spec{} = spec), do: GenServer.start(__MODULE__, spec)

  @spec stop(pid()) :: :ok
  def stop(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.cast(pid, :stop)
    :ok
  end

  @impl GenServer
  def init(%Spec{task_id: nil}), do: {:stop, :task_id_required}

  def init(%Spec{} = spec) do
    state = %__MODULE__{
      owner: spec.owner_pid,
      session_id: spec.session_id,
      task_id: spec.task_id,
      spec: spec
    }

    {:ok, state, {:continue, :start_exec}}
  end

  @impl GenServer
  def handle_continue(:start_exec, state) do
    case start_exec(state) do
      {:ok, state} -> {:noreply, state}
      {:error, reason} -> {:stop, reason, state}
    end
  end

  @impl GenServer
  def handle_cast(:stop, state), do: {:stop, :normal, state}

  @impl GenServer
  def format_status(status) do
    update_in(status.state.spec, &Spec.redact/1)
  end

  @impl GenServer
  def handle_info({:chunk, bytes}, %__MODULE__{} = state) do
    send(state.owner, {:runner_data, self(), bytes})
    {:noreply, state}
  end

  def handle_info({:stream_done, _}, state), do: {:noreply, state}

  def handle_info({:exit_code, code}, %__MODULE__{} = state) do
    # Prefer the exec-wrapper's tee'd file (complete even if the live
    # stream was cut) as the authoritative result; fall back to the
    # streamed buffer on any failure.
    case fetch_output_file(state) do
      {:ok, bytes} when bytes != "" ->
        send(state.owner, {:runner_output, self(), bytes})

      _ ->
        :ok
    end

    send(state.owner, {:runner_exit, self(), code})
    {:stop, :normal, state}
  end

  def handle_info({ref, _}, state) when is_reference(ref), do: {:noreply, state}
  def handle_info({:DOWN, _, _, _, _}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  defp start_exec(%__MODULE__{spec: spec} = state) do
    with {:ok, tc_pid} <- TaskContainer.ensure_started(spec),
         {:ok, container_id} <- TaskContainer.get_container_id(tc_pid),
         :ok <- wait_for_ready(container_id),
         {:ok, exec_id} <- create_exec(container_id, spec) do
      state = %{state | container_id: container_id, exec_id: exec_id}
      {:ok, kick_off_streams(state)}
    end
  end

  defp wait_for_ready(container_id) do
    case ready_check(container_id) do
      :ok ->
        :ok

      :not_ready ->
        Process.sleep(@ready_poll_ms)
        wait_for_ready(container_id)

      {:error, _} = err ->
        err
    end
  end

  defp ready_check(container_id) do
    payload = %{
      "AttachStdout" => false,
      "AttachStderr" => false,
      "Cmd" => ["test", "-f", "/tmp/camelot-ready"]
    }

    with {:ok, %Req.Response{status: 201, body: %{"Id" => exec_id}}} <-
           Req.post(DockerApi.request(), url: "/containers/#{container_id}/exec", json: payload),
         {:ok, _} <-
           Req.post(DockerApi.request(),
             url: "/exec/#{exec_id}/start",
             json: %{"Detach" => false}
           ),
         {:ok, %Req.Response{status: 200, body: %{"ExitCode" => code}}} <-
           Req.get(DockerApi.request(), url: "/exec/#{exec_id}/json") do
      if code == 0, do: :ok, else: :not_ready
    else
      {:ok, resp} -> {:error, {:bad_status, resp.status, resp.body}}
      {:error, _} = err -> err
    end
  end

  defp create_exec(container_id, %Spec{} = spec) do
    payload = %{
      "AttachStdout" => true,
      "AttachStderr" => true,
      "AttachStdin" => false,
      "Tty" => false,
      "WorkingDir" => spec.cwd,
      "Env" => session_env(spec),
      "Cmd" => ["/exec-wrapper.sh"] ++ spec.argv
    }

    case Req.post(DockerApi.request(),
           url: "/containers/#{container_id}/exec",
           json: reject_nil(payload)
         ) do
      {:ok, %Req.Response{status: 201, body: %{"Id" => exec_id}}} ->
        {:ok, exec_id}

      {:ok, resp} ->
        {:error, {:exec_create_failed, resp.status, resp.body}}

      {:error, _} = err ->
        err
    end
  end

  # Build the per-exec `Env` array. Always re-materialises secrets
  # from the current Spec so a credential rotation in the UI takes
  # effect on the next session without rebuilding the container.
  # The exec-wrapper treats /tmp/camelot.env as a fallback only;
  # these values override anything baked in at container start.
  defp session_env(%Spec{} = spec) do
    session_id_env(spec) ++ secret_env(spec) ++ mcp_env(spec)
  end

  # The exec-wrapper tees output to /tmp/camelot-output-<id>.log so we
  # can fetch it after exit; it needs the session id to name the file.
  defp session_id_env(%Spec{session_id: id}), do: ["CAMELOT_SESSION_ID=#{id}"]

  defp secret_env(%Spec{secrets: secrets}) do
    Enum.flat_map(secrets, &secret_to_env/1)
  end

  defp mcp_env(%Spec{mcp_config_json: nil}), do: []
  defp mcp_env(%Spec{mcp_config_json: json}), do: ["PROJECT_MCP_CONFIG_JSON=#{json}"]

  # Mirror runner-images/base/entrypoint.sh#materialise_one — an
  # `sk-ant-oat*` value is an OAuth access token that Claude reads
  # from CLAUDE_CODE_OAUTH_TOKEN (sending it on x-api-key would 401).
  # Everything else is a plain API key.
  # When the OAuth path is in play, also explicitly clear
  # ANTHROPIC_API_KEY in the exec env so that any stale value
  # baked into the container (e.g. from a previous credential or
  # the old TaskContainer mapping) can't beat us. claude treats
  # an empty value as unset and falls back to CLAUDE_CODE_OAUTH_TOKEN.
  defp secret_to_env(%{kind: :claude_api_key, value: "sk-ant-oat" <> _ = v}) do
    ["CLAUDE_CODE_OAUTH_TOKEN=#{v}", "ANTHROPIC_API_KEY="]
  end

  defp secret_to_env(%{kind: :claude_api_key, value: v}) do
    ["ANTHROPIC_API_KEY=#{v}", "CLAUDE_CODE_OAUTH_TOKEN="]
  end

  defp secret_to_env(%{kind: :openai_api_key, value: v}), do: ["OPENAI_API_KEY=#{v}"]
  defp secret_to_env(%{kind: :codex_api_key, value: v}), do: ["OPENAI_API_KEY=#{v}"]

  defp secret_to_env(%{kind: kind, value: v}) when kind in [:github_pat, :github_oauth],
    do: ["GH_TOKEN=#{v}", "GITHUB_TOKEN=#{v}"]

  defp secret_to_env(%{kind: kind, value: v}) do
    ["CAMELOT_SECRET_#{String.upcase(Atom.to_string(kind))}=#{v}"]
  end

  defp kick_off_streams(%__MODULE__{} = state) do
    parent = self()

    stream_task =
      Task.async(fn -> stream_exec(state.exec_id, parent) end)

    poll_task =
      Task.async(fn -> poll_exec_exit(state.exec_id, parent) end)

    %{state | stream_task: stream_task, poll_task: poll_task}
  end

  defp stream_exec(exec_id, parent) do
    Req.post(DockerApi.request(),
      url: "/exec/#{exec_id}/start",
      json: %{"Detach" => false, "Tty" => false},
      receive_timeout: :infinity,
      into: fn {:data, chunk}, {req, resp} ->
        demux(chunk, parent)
        {:cont, {req, resp}}
      end
    )

    send(parent, {:stream_done, make_ref()})
  rescue
    e ->
      Logger.warning("DockerEngine.ExecSession stream crashed: #{inspect(e)}")
      send(parent, {:stream_done, make_ref()})
  end

  defp demux(chunk, parent) do
    buf = Process.get(:de_demux_buf, <<>>)
    {payloads, rest} = DockerStreamDemux.drain(buf, chunk)
    Enum.each(payloads, fn payload -> send(parent, {:chunk, payload}) end)
    Process.put(:de_demux_buf, rest)
  end

  # An exec inspect returns `Running: false, ExitCode: nil` between
  # `POST /containers/<id>/exec` (which creates the exec) and
  # `POST /exec/<id>/start` (which actually starts it). Treat that
  # pre-start state the same as "still running" — only ExitCode as
  # an integer means the process has actually exited.
  defp poll_exec_exit(exec_id, parent) do
    case Req.get(DockerApi.request(), url: "/exec/#{exec_id}/json") do
      {:ok, %Req.Response{status: 200, body: %{"Running" => false, "ExitCode" => code}}}
      when is_integer(code) ->
        send(parent, {:exit_code, code})

      _ ->
        Process.sleep(@exit_poll_ms)
        poll_exec_exit(exec_id, parent)
    end
  end

  # Fetch the exec-wrapper's tee'd output file with a short `cat`
  # exec — complete even if the long-lived agent stream was severed.
  # Returns `:error` (caller falls back to the streamed buffer) on any
  # missing field or Docker error.
  defp fetch_output_file(%__MODULE__{session_id: sid, container_id: cid}) when is_binary(sid) and is_binary(cid) do
    payload = %{
      "AttachStdout" => true,
      "AttachStderr" => false,
      "Tty" => false,
      "Cmd" => ["cat", "/tmp/camelot-output-#{sid}.log"]
    }

    with {:ok, %Req.Response{status: 201, body: %{"Id" => exec_id}}} <-
           Req.post(DockerApi.request(), url: "/containers/#{cid}/exec", json: payload),
         {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) <-
           Req.post(DockerApi.request(),
             url: "/exec/#{exec_id}/start",
             json: %{"Detach" => false, "Tty" => false}
           ) do
      {payloads, _rest} = DockerStreamDemux.drain(<<>>, body)
      {:ok, IO.iodata_to_binary(payloads)}
    else
      _ -> :error
    end
  end

  defp fetch_output_file(_), do: :error

  defp reject_nil(map) when is_map(map) do
    map
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end
end
