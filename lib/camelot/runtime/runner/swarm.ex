defmodule Camelot.Runtime.Runner.Swarm do
  @moduledoc """
  Runner backend that creates one-shot Swarm services
  via the Docker Swarm manager API. Used in hosted
  multi-node deployments.

  Each session becomes a service named
  `camelot-runner-<session_id>`, scheduled onto the
  node carrying the user's `camelot-home` label,
  reserving the resources declared on the agent
  template, and mounting the per-user profile volume.
  Credentials arrive via Swarm secrets maintained by
  `Camelot.Runtime.SecretSync`.

  Logs are streamed via the `/services/{id}/logs`
  endpoint. Exit is detected by polling
  `/services/{id}/tasks` until the task state moves
  out of `running`.
  """
  @behaviour Camelot.Runtime.Runner

  use GenServer, restart: :temporary

  alias Camelot.Runtime.Runner
  alias Camelot.Runtime.Runner.DockerApi
  alias Camelot.Runtime.Runner.Spec
  alias Camelot.Runtime.SecretSync

  require Logger

  @poll_interval_ms 2_000
  @pending_grace_ms 30_000
  @log_retention_ms 300_000

  defstruct [
    :owner,
    :service_id,
    :session_id,
    :log_task,
    :poll_task,
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
    case create_service(spec) do
      {:ok, service_id} ->
        state = %__MODULE__{
          owner: spec.owner_pid,
          service_id: service_id,
          session_id: spec.session_id,
          spec: spec
        }

        {:ok, kick_off_streams(state)}

      {:error, reason} ->
        Logger.error("Swarm start failed: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_cast(:stop, state) do
    remove_service(state.service_id)
    {:stop, :normal, state}
  end

  @impl GenServer
  def handle_info({:log_chunk, bytes}, state) do
    send(state.owner, {:runner_data, self(), bytes})
    {:noreply, state}
  end

  def handle_info({:log_done, _}, state), do: {:noreply, state}

  def handle_info({:exit_code, code}, state) do
    send(state.owner, {:runner_exit, self(), code})
    schedule_cleanup()
    {:noreply, state}
  end

  def handle_info({:cluster_full, reason}, state) do
    send(state.owner, {:runner_data, self(), "[swarm] cluster_full: #{inspect(reason)}\n"})
    send(state.owner, {:runner_exit, self(), 125})
    schedule_cleanup()
    {:noreply, state}
  end

  def handle_info(:cleanup, state) do
    remove_service(state.service_id)
    {:stop, :normal, state}
  end

  def handle_info({ref, _}, state) when is_reference(ref), do: {:noreply, state}
  def handle_info({:DOWN, _, _, _, _}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @log_retention_ms)
  end

  # --- Service create ---

  defp create_service(%Spec{} = spec) do
    name = spec.service_name || Spec.service_name(spec.session_id)
    payload = service_create_payload(spec, name)

    case Req.post(DockerApi.request(), url: "/services/create", json: payload) do
      {:ok, %Req.Response{status: status, body: %{"ID" => id}}} when status in 200..299 ->
        {:ok, id}

      {:ok, resp} ->
        {:error, {:create_failed, resp.status, resp.body}}

      {:error, _} = err ->
        err
    end
  end

  defp remove_service(nil), do: :ok

  defp remove_service(id) do
    #Req.delete(DockerApi.request(), url: "/services/#{id}")
    :ok
  rescue
    _ -> :ok
  end

  defp service_create_payload(%Spec{} = spec, name) do
    reject_nil(%{
      "Name" => name,
      "TaskTemplate" => %{
        "ContainerSpec" => container_spec(spec),
        "Placement" => placement(spec),
        "Resources" => resources(spec),
        "RestartPolicy" => %{"Condition" => "none"}
      },
      "Mode" => %{"Replicated" => %{"Replicas" => 1}}
    })
  end

  defp container_spec(%Spec{} = spec) do
    reject_nil(%{
      "Image" => spec.image || "alpine:latest",
      "Command" => spec.argv,
      "Env" => env_pairs(spec),
      "Dir" => spec.cwd,
      "Mounts" => mounts(spec),
      "Secrets" => secrets(spec)
    })
  end

  defp env_pairs(%Spec{} = spec) do
    base = Enum.map(spec.env, fn {k, v} -> "#{k}=#{v}" end)
    extras = bootstrap_env(spec) ++ repo_env(spec) ++ mcp_env(spec)
    base ++ extras
  end

  defp bootstrap_env(%Spec{bootstrap?: true}), do: ["BOOTSTRAP=1"]
  defp bootstrap_env(_), do: []

  defp repo_env(%Spec{repo_url: nil}), do: []

  defp repo_env(%Spec{repo_url: url, repo_branch: branch}) do
    ["REPO_URL=#{url}"] ++ if(branch, do: ["REPO_BRANCH=#{branch}"], else: [])
  end

  defp mcp_env(%Spec{mcp_config_json: nil}), do: []
  defp mcp_env(%Spec{mcp_config_json: json}), do: ["PROJECT_MCP_CONFIG_JSON=#{json}"]

  defp mounts(%Spec{profile_volume: nil}), do: []

  defp mounts(%Spec{profile_volume: vol}) do
    [
      %{
        "Target" => "/home/agent",
        "Source" => vol,
        "Type" => "volume",
        "ReadOnly" => false
      }
    ]
  end

  defp secrets(%Spec{secrets: []}), do: []

  defp secrets(%Spec{secrets: secrets}) do
    Enum.flat_map(secrets, fn %{kind: kind, name: name} ->
      case SecretSync.lookup_id_by_name(name) do
        {:ok, id} ->
          [
            %{
              "SecretID" => id,
              "SecretName" => name,
              "File" => %{
                "Name" => Atom.to_string(kind),
                "UID" => "1000",
                "GID" => "1000",
                "Mode" => 0o400
              }
            }
          ]

        :error ->
          Logger.warning("Swarm: secret #{name} not found in cluster; runner will start without /run/secrets/#{kind}")

          []
      end
    end)
  end

  defp placement(%Spec{node_label: nil}), do: %{}

  defp placement(%Spec{node_label: label}) do
    %{"Constraints" => ["node.labels.camelot-home==#{label}"]}
  end

  defp resources(%Spec{resources: r}) when map_size(r) == 0, do: %{}

  defp resources(%Spec{resources: r}) do
    %{
      "Reservations" => reject_nil(%{"NanoCPUs" => parse_cpu(r["cpu"]), "MemoryBytes" => parse_memory(r["memory"])})
    }
  end

  defp parse_cpu(nil), do: nil

  defp parse_cpu(value) when is_binary(value) do
    case Float.parse(value) do
      {f, _} -> trunc(f * 1_000_000_000)
      :error -> nil
    end
  end

  defp parse_memory(nil), do: nil

  defp parse_memory(value) when is_binary(value) do
    case Regex.run(~r/^(\d+)([GMK])?$/i, value) do
      [_, n, unit] -> String.to_integer(n) * unit_multiplier(unit)
      [_, n] -> String.to_integer(n)
      _ -> nil
    end
  end

  defp unit_multiplier(u) do
    case String.upcase(u) do
      "G" -> 1024 * 1024 * 1024
      "M" -> 1024 * 1024
      "K" -> 1024
      _ -> 1
    end
  end

  defp reject_nil(map) when is_map(map) do
    map
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end

  # --- Streaming + polling ---

  defp kick_off_streams(%__MODULE__{} = state) do
    parent = self()
    id = state.service_id

    log_task =
      Task.async(fn ->
        stream_logs(id, parent)
      end)

    poll_task =
      Task.async(fn ->
        poll_until_exit(id, parent)
      end)

    %{state | log_task: log_task, poll_task: poll_task}
  end

  defp stream_logs(service_id, parent) do
    Req.get(DockerApi.request(),
      url: "/services/#{service_id}/logs",
      params: [stdout: true, stderr: true, follow: true],
      receive_timeout: :infinity,
      into: fn {:data, chunk}, {req, resp} ->
        send(parent, {:log_chunk, chunk})
        {:cont, {req, resp}}
      end
    )

    send(parent, {:log_done, make_ref()})
  rescue
    e ->
      Logger.warning("Swarm log stream crashed: #{inspect(e)}")
      send(parent, {:log_done, make_ref()})
  end

  defp poll_until_exit(service_id, parent, started_at \\ System.monotonic_time(:millisecond)) do
    case fetch_task_state(service_id) do
      {:ok, %{"State" => state} = task} when state in ["complete", "failed", "shutdown"] ->
        code = exit_code_from_task(task)
        send(parent, {:exit_code, code})

      {:ok, %{"State" => "pending"}} ->
        elapsed = System.monotonic_time(:millisecond) - started_at

        if elapsed > @pending_grace_ms do
          send(parent, {:cluster_full, :pending_grace_exceeded})
        else
          Process.sleep(@poll_interval_ms)
          poll_until_exit(service_id, parent, started_at)
        end

      {:ok, %{"State" => _}} ->
        Process.sleep(@poll_interval_ms)
        poll_until_exit(service_id, parent, started_at)

      {:ok, :no_task} ->
        Process.sleep(@poll_interval_ms)
        poll_until_exit(service_id, parent, started_at)

      {:error, reason} ->
        Logger.warning("Swarm poll failed: #{inspect(reason)}")
        Process.sleep(@poll_interval_ms)
        poll_until_exit(service_id, parent, started_at)
    end
  end

  defp fetch_task_state(service_id) do
    case Req.get(DockerApi.request(), url: "/tasks", params: [filters: ~s({"service":["#{service_id}"]})]) do
      {:ok, %Req.Response{status: 200, body: tasks}} when is_list(tasks) ->
        case List.last(tasks) do
          nil -> {:ok, :no_task}
          task -> {:ok, Map.merge(%{"State" => get_in(task, ["Status", "State"]) || "unknown"}, task)}
        end

      {:ok, resp} ->
        {:error, {:bad_status, resp.status}}

      {:error, _} = err ->
        err
    end
  end

  defp exit_code_from_task(task) do
    case get_in(task, ["Status", "ContainerStatus", "ExitCode"]) do
      n when is_integer(n) -> n
      _ -> 1
    end
  end
end
