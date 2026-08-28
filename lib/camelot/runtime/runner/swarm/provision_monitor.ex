defmodule Camelot.Runtime.Runner.Swarm.ProvisionMonitor do
  @moduledoc """
  Watches the Swarm side of a session's hand-off and reports
  what it sees through `Camelot.Runtime.Progress`.

  `ExecSession.start_exec/1` blocks — sometimes for many
  minutes — inside `TaskService.get_service_id/1`,
  `resolve_container/2` and `wait_for_ready/3`, none of which
  can talk to the user while they poll. This GenServer runs
  alongside for exactly that window and answers the only
  question the user has: *what is it doing right now?*

  Every `@poll_ms` it asks the Swarm manager for the tasks of
  `camelot-task-<task_id>` and maps their state to a line:
  scheduling, pulling the image, starting the container. Once
  a replica runs, the wait moves inside the container
  (`git clone`, `asdf install`), so it tails that container's
  logs through the node proxy and surfaces the entrypoint's
  own words. Only changes are reported, so a long pull emits
  one line, not one per poll.

  Started and stopped by `ExecSession`; dies with it.
  """
  use GenServer, restart: :temporary

  alias Camelot.Runtime.Progress
  alias Camelot.Runtime.Runner.DockerApi
  alias Camelot.Runtime.Runner.DockerStreamDemux
  alias Camelot.Runtime.Runner.Spec
  alias Camelot.Runtime.Runner.Swarm.ProxyRouter

  require Logger

  # Slow on purpose: this is a status line for a human, not a
  # control loop. The 500ms polls in `ExecSession` drive the
  # actual hand-off.
  @poll_ms 3_000

  # Entrypoint lines are short; a handful covers the tail.
  @log_tail 5

  @entrypoint_prefix "[entrypoint] "

  defstruct [:task_id, :session_id, :service_name, :last]

  @type t :: %__MODULE__{
          task_id: String.t(),
          session_id: String.t() | nil,
          service_name: String.t(),
          last: String.t() | nil
        }

  # --- Public API ---

  @doc """
  Start watching the runner service behind `task_id`. Returns
  `nil` when there is nothing to watch or the process could
  not start — callers treat monitoring as best-effort.
  """
  @spec start(String.t() | nil, String.t() | nil) :: pid() | nil
  def start(nil, _session_id), do: nil

  def start(task_id, session_id) when is_binary(task_id) do
    case GenServer.start(__MODULE__, {task_id, session_id}) do
      {:ok, pid} ->
        pid

      {:error, reason} ->
        Logger.warning("ProvisionMonitor #{task_id}: not started: #{inspect(reason)}")
        nil
    end
  end

  @spec stop(pid() | nil) :: :ok
  def stop(nil), do: :ok

  def stop(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    :ok
  end

  # --- GenServer ---

  @impl GenServer
  def init({task_id, session_id}) do
    state = %__MODULE__{
      task_id: task_id,
      session_id: session_id,
      service_name: Spec.task_runner_name(task_id)
    }

    {:ok, state, {:continue, :probe}}
  end

  @impl GenServer
  def handle_continue(:probe, state), do: {:noreply, probe_and_report(state)}

  @impl GenServer
  def handle_info(:probe, state), do: {:noreply, probe_and_report(state)}

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Probing ---

  defp probe_and_report(state) do
    {phase, message} = probe(state)

    Process.send_after(self(), :probe, @poll_ms)
    report_change(state, phase, message)
  end

  defp report_change(%__MODULE__{last: message} = state, _phase, message), do: state

  defp report_change(state, phase, message) do
    Progress.report(state.task_id, state.session_id, phase, message)
    %{state | last: message}
  end

  defp probe(state) do
    case list_tasks(state.service_name) do
      {:ok, tasks} -> describe_placement(describe_tasks(tasks))
      {:error, _reason} -> {:provisioning, "Waiting for the runner service…"}
    end
  end

  defp describe_placement({:running, container_id, node_id}) do
    container_id
    |> entrypoint_hint(node_id)
    |> workspace_progress()
  end

  defp describe_placement({phase, message}), do: {phase, message}

  defp list_tasks(service_name) do
    case Req.get(DockerApi.request(),
           url: "/tasks",
           params: [filters: ~s({"service":["#{service_name}"]})]
         ) do
      {:ok, %Req.Response{status: 200, body: tasks}} when is_list(tasks) -> {:ok, tasks}
      {:ok, resp} -> {:error, {:tasks_bad_status, resp.status}}
      {:error, _} = err -> err
    end
  end

  # --- Swarm task state -> user-facing line ---

  @doc """
  Maps the Docker `GET /tasks` list of a runner service to
  either the live placement (`{:running, container_id,
  node_id}`, so the caller can tail its logs) or a
  `{phase, message}` line describing what Swarm is doing.

  Only the newest task is considered: Swarm keeps historical
  records, and a shut-down replica would otherwise mask the
  one actually being provisioned — the same trap
  `ExecSession.pick_running_task/1` guards against.
  """
  @spec describe_tasks([map()]) ::
          {:running, String.t(), String.t()} | {Progress.phase(), String.t()}
  def describe_tasks([]), do: {:provisioning, "Creating the runner service…"}

  def describe_tasks(tasks) do
    tasks
    |> Enum.max_by(&(&1["CreatedAt"] || ""), fn -> nil end)
    |> describe_task()
  end

  defp describe_task(nil), do: {:provisioning, "Creating the runner service…"}

  defp describe_task(task) do
    state = get_in(task, ["Status", "State"])
    container_id = get_in(task, ["Status", "ContainerStatus", "ContainerID"])
    node_id = task["NodeID"]

    describe_state(state, container_id, node_id, task_detail(task))
  end

  defp describe_state("running", cid, node, _detail) when is_binary(cid) and is_binary(node) do
    {:running, cid, node}
  end

  # Placed but no container id yet — the daemon is still bringing
  # it up; same story for the user as `starting`.
  defp describe_state("running", _cid, _node, detail) do
    {:starting, join("Starting the runner container…", detail)}
  end

  defp describe_state("preparing", _cid, _node, detail) do
    {:pulling_image, join("Pulling the runner image…", detail)}
  end

  defp describe_state("starting", _cid, _node, detail) do
    {:starting, join("Starting the runner container…", detail)}
  end

  defp describe_state(state, _cid, _node, detail) when state in ~w(failed rejected orphaned) do
    {:provisioning, join("Runner replica #{state}; Swarm is retrying…", detail)}
  end

  defp describe_state(_state, _cid, _node, detail) do
    {:provisioning, join("Scheduling the runner on a node…", detail)}
  end

  # Swarm explains a stuck placement in `Status.Err` ("no suitable
  # node…") and narrates the rest in `Status.Message`. The error is
  # the one worth showing.
  defp task_detail(task) do
    case get_in(task, ["Status", "Err"]) do
      err when is_binary(err) and err != "" -> err
      _ -> nil
    end
  end

  defp join(message, nil), do: message
  defp join(message, detail), do: "#{message} #{detail}"

  # --- In-container progress ---

  @doc """
  Builds the line shown while the container is up but the agent
  has not started — the `git clone` / `asdf install` window.
  """
  @spec workspace_progress(String.t() | nil) :: {Progress.phase(), String.t()}
  def workspace_progress(nil), do: {:workspace, "Setting up the workspace…"}

  def workspace_progress(entrypoint_line) do
    {:workspace, "Setting up the workspace: #{entrypoint_line}"}
  end

  @doc """
  Extracts the last `[entrypoint] …` line from a container log
  tail, with the prefix stripped. Accepts Docker's multiplexed
  frame format and plain bytes alike; returns nil when the
  entrypoint has said nothing yet.
  """
  @spec entrypoint_line(binary()) :: String.t() | nil
  def entrypoint_line(logs) when is_binary(logs) do
    logs
    |> decode_logs()
    |> String.split("\n", trim: true)
    |> Enum.reverse()
    |> Enum.find_value(nil, &strip_prefix/1)
  end

  defp strip_prefix(line) do
    case String.split(line, @entrypoint_prefix, parts: 2) do
      [_before, text] -> String.trim(text)
      _ -> nil
    end
  end

  # Service containers run without a TTY, so `GET /logs` returns
  # multiplexed frames. Fall back to the raw bytes for the TTY
  # case (and for tests feeding plain text).
  defp decode_logs(logs) do
    case DockerStreamDemux.drain("", logs) do
      {[_ | _] = payloads, _rest} -> Enum.join(payloads)
      _ -> logs
    end
  end

  defp entrypoint_hint(container_id, node_id) do
    with {:ok, node_req} <- ProxyRouter.request_for_node(node_id),
         {:ok, %Req.Response{status: 200, body: body}} <-
           Req.get(node_req,
             url: "/containers/#{container_id}/logs",
             params: [stdout: true, stderr: true, tail: @log_tail],
             decode_body: false
           ) do
      entrypoint_line(body)
    else
      _ -> nil
    end
  end
end
