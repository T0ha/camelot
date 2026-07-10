defmodule Camelot.Runtime.Reconciler do
  @moduledoc """
  Reconciles persistent session state in PostgreSQL
  with the live Docker/Swarm reality, both at boot and
  periodically (every minute).

  On boot:

    1. Recovers any `Session{status: :running}` rows whose
       owning AgentProcess is gone (e.g. after a redeploy).
       If the session's task runner container is still
       alive, it is **adopted** — a fresh AgentProcess
       re-attaches and finalises from the durable tee'd
       output (`was_adopted` is set). Only when there is no
       live container to re-attach to (bootstrap sessions,
       the LocalPort backend, or a truly gone runner) is the
       session marked failed for the user to retry.
    2. Queued sessions are *not* touched — their DB rows
       survive untouched, and the next call to
       `RunnerPool.tick/0` (after AgentProcess
       processes restart and re-enqueue) drains them
       normally.
    3. Sweeps orphan `camelot-runner-*` services that no
       longer have a `:queued` or `:running` session row.
    4. Sweeps tasks whose `runner_handle` points to a
       stale backend service (node partition, manual
       `docker service rm`, swarm reschedule failure).
       For Swarm services that still exist but have zero
       runnable tasks, triggers a `force-redeploy` (bumps
       `Spec.TaskTemplate.ForceUpdate`) so the swarm
       reschedules without losing the service identity.
       Only after the redeploy fails to yield a runnable
       task within `@redeploy_wait_ms`, or when the service
       is genuinely 404, the task is marked
       `state: :error` and `runner_handle` cleared so the
       user can retry. A 15-minute grace on `updated_at`
       keeps in-flight dispatches from being false-positives.

  In steady state, the same sweep runs every 60s to
  catch any drift Camelot didn't notice (manual
  `docker service rm`, network blips during cleanup,
  etc.).
  """
  use GenServer

  alias Camelot.Agents.Session
  alias Camelot.Board.Task
  alias Camelot.Runtime.AgentProcess
  alias Camelot.Runtime.AgentRegistry
  alias Camelot.Runtime.AgentSupervisor
  alias Camelot.Runtime.Runner
  alias Camelot.Runtime.Runner.DockerApi
  alias Camelot.Runtime.Runner.LocalPort
  alias Camelot.Runtime.Runner.Swarm
  alias Camelot.Runtime.RunnerPool
  alias Camelot.Runtime.SessionRegistry

  require Ash.Query
  require Logger

  @tick_ms 60_000
  @log_retention_ms 300_000
  @stale_runner_grace_ms 900_000
  @redeploy_wait_ms 15_000
  @redeploy_poll_ms 1_000
  @name __MODULE__

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc """
  Run a reconciliation pass synchronously. Mostly for
  tests and manual operator calls.
  """
  @spec reconcile_now() :: :ok
  def reconcile_now, do: GenServer.call(@name, :reconcile_now, 30_000)

  @impl GenServer
  def init(_opts) do
    if !skip_initial_tick?(), do: Process.send_after(self(), :tick, initial_delay_ms())
    {:ok, %{}}
  end

  defp skip_initial_tick? do
    # Tests configure :camelot, :reconciler, autostart: false to keep the
    # DB-sandbox-owning process from being the wrong owner.
    :camelot
    |> Application.get_env(:reconciler, [])
    |> Keyword.get(:autostart, true)
    |> Kernel.==(false)
  end

  defp initial_delay_ms do
    :camelot
    |> Application.get_env(:reconciler, [])
    |> Keyword.get(:initial_delay_ms, 1_000)
  end

  @impl GenServer
  def handle_call(:reconcile_now, _from, state) do
    do_reconcile()
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    do_reconcile()
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Reconciliation pass ---

  defp do_reconcile do
    fail_stale_running_sessions()

    if backend_available?() do
      live_sessions = list_runner_services()
      sweep_orphan_services(live_sessions)

      live_tasks = list_task_runners()
      sweep_orphan_task_runners(live_tasks)
      sweep_stale_task_runner_handles()

      RunnerPool.tick()
    else
      Logger.debug("Reconciler: backend unavailable, skipping sweep")
      :ok
    end
  rescue
    e ->
      Logger.warning("Reconciler pass failed: #{Exception.message(e)}")
      :ok
  end

  defp fail_stale_running_sessions do
    Session
    |> Ash.Query.filter(status == :running)
    |> Ash.read!()
    |> Enum.each(&recover_stale_session/1)
  end

  # A `:running` session whose owning AgentProcess is gone (typically
  # after a redeploy). If its task runner container is still alive we
  # adopt it — re-attach and finalise from the durable tee'd output —
  # instead of discarding in-flight work. Only when the container is
  # truly gone (or this is a bootstrap/LocalPort session with nothing
  # to re-attach to) do we fail it so the user can retry.
  defp recover_stale_session(session) do
    if alive_owner?(session) do
      :ok
    else
      handle = session.task_id && task_runner_handle(session.task_id)
      presence = if handle, do: probe_runner(handle), else: :gone

      case recovery_action(Runner.backend(), session.kind, handle, presence) do
        :adopt -> adopt_stale_session(session)
        :fail -> fail_stale_session(session)
      end
    end
  end

  @doc """
  Pure decision for a stale `:running` session: `:adopt` only when a
  task session's runner container is actually running; otherwise
  `:fail`. Bootstrap sessions and the LocalPort backend have no
  re-attachable container.
  """
  @spec recovery_action(module(), atom(), String.t() | nil, atom()) :: :adopt | :fail
  def recovery_action(LocalPort, _kind, _handle, _presence), do: :fail
  def recovery_action(_backend, :bootstrap, _handle, _presence), do: :fail
  def recovery_action(_backend, _kind, nil, _presence), do: :fail
  def recovery_action(_backend, _kind, _handle, :present), do: :adopt
  def recovery_action(_backend, _kind, _handle, _presence), do: :fail

  defp adopt_stale_session(%Session{} = session) do
    Logger.info(
      "Reconciler: adopting running session #{session.id} " <>
        "(runner container still alive)"
    )

    with :ok <- ensure_agent_process(session.agent_id),
         :ok <- AgentProcess.adopt(session.agent_id, session.id) do
      :ok
    else
      other ->
        Logger.warning(
          "Reconciler: adopt failed for session #{session.id} " <>
            "(#{inspect(other)}); failing it instead"
        )

        fail_stale_session(session)
    end
  end

  defp ensure_agent_process(agent_id) do
    case AgentRegistry.lookup(agent_id) do
      nil ->
        case AgentSupervisor.start_agent(agent_id) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, _} = err -> err
        end

      _pid ->
        :ok
    end
  end

  defp fail_stale_session(%Session{} = session) do
    Logger.info(
      "Reconciler: failing stale running session #{session.id} " <>
        "(owning AgentProcess not registered, no adoptable runner)"
    )

    Ash.update!(
      session,
      %{
        error_message:
          "AgentProcess unregistered without finalising this session " <>
            "and no live runner container was available to adopt. " <>
            "The session can be retried.",
        exit_code: 1
      },
      action: :fail
    )
  end

  defp task_runner_handle(task_id) do
    case Ash.get(Task, task_id) do
      {:ok, %Task{runner_handle: handle}} -> handle
      _ -> nil
    end
  end

  defp alive_owner?(%Session{id: id}) do
    case SessionRegistry.lookup(id) do
      pid when is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end
  end

  defp backend_available? do
    backend = Runner.backend()

    if backend == LocalPort do
      true
    else
      case DockerApi.ping() do
        :ok -> true
        _ -> false
      end
    end
  end

  defp list_runner_services do
    list_runners_with_prefix("camelot-runner-")
  end

  defp list_task_runners do
    list_runners_with_prefix("camelot-task-")
  end

  defp list_runners_with_prefix(prefix) do
    if Runner.backend() == Swarm do
      list_swarm_services(prefix)
    else
      list_engine_containers(prefix)
    end
  end

  defp list_swarm_services(prefix) do
    filters = ~s({"name":["#{prefix}"]})

    case Req.get(DockerApi.request(), url: "/services", params: [filters: filters]) do
      {:ok, %Req.Response{status: 200, body: services}} when is_list(services) ->
        Enum.flat_map(services, &extract_id(get_in(&1, ["Spec", "Name"]), prefix))

      _ ->
        []
    end
  end

  defp list_engine_containers(prefix) do
    filters = ~s({"name":["#{prefix}"]})

    case Req.get(DockerApi.request(),
           url: "/containers/json",
           params: [all: true, filters: filters]
         ) do
      {:ok, %Req.Response{status: 200, body: containers}} when is_list(containers) ->
        Enum.flat_map(containers, fn c ->
          name = c |> Map.get("Names", []) |> List.first() |> String.trim_leading("/")
          extract_id(name, prefix)
        end)

      _ ->
        []
    end
  end

  defp extract_id(nil, _prefix), do: []

  defp extract_id(name, prefix) when is_binary(name) do
    case String.split(name, prefix, parts: 2) do
      ["", id] -> [id]
      _ -> []
    end
  end

  defp sweep_orphan_services(live_session_ids) do
    cutoff = DateTime.add(DateTime.utc_now(), -@log_retention_ms, :millisecond)

    valid =
      Session
      |> Ash.Query.filter(
        status in [:queued, :running] or
          (not is_nil(finished_at) and finished_at > ^cutoff)
      )
      |> Ash.Query.select([:id])
      |> Ash.read!()
      |> MapSet.new(& &1.id)

    Enum.each(live_session_ids, fn id ->
      if !MapSet.member?(valid, id) do
        Logger.info("Reconciler: removing orphan runner for session #{id}")
        remove_runner_for(id)
      end
    end)
  end

  defp remove_runner_for(session_id) do
    name = "camelot-runner-#{session_id}"
    delete_by_name(name)
  end

  defp sweep_orphan_task_runners(live_task_ids) do
    cutoff = DateTime.add(DateTime.utc_now(), -@log_retention_ms, :millisecond)

    valid =
      Task
      |> Ash.Query.filter(
        stage not in [:done, :cancelled] or
          updated_at > ^cutoff
      )
      |> Ash.Query.select([:id])
      |> Ash.read!()
      |> MapSet.new(& &1.id)

    Enum.each(live_task_ids, fn id ->
      if !MapSet.member?(valid, id) do
        Logger.info("Reconciler: removing orphan task runner for task #{id}")
        remove_task_runner_for(id)
      end
    end)
  end

  defp remove_task_runner_for(task_id) do
    name = "camelot-task-#{task_id}"
    delete_by_name(name)
  end

  # Probe per-task (not via bulk list) so a transient Docker API
  # hiccup can't false-positive every in-flight task at once.
  defp sweep_stale_task_runner_handles do
    cutoff =
      DateTime.add(DateTime.utc_now(), -@stale_runner_grace_ms, :millisecond)

    Task
    |> Ash.Query.filter(
      not is_nil(runner_handle) and
        state == :in_progress and
        stage in [:planning, :executing] and
        updated_at < ^cutoff
    )
    |> Ash.read!()
    |> Enum.each(&maybe_mark_runner_lost/1)
  end

  defp maybe_mark_runner_lost(%Task{} = task) do
    case probe_runner(task.runner_handle) do
      :present -> :ok
      :gone -> mark_runner_lost(task, "service returned 404")
      :no_tasks -> attempt_force_redeploy(task)
      :unknown -> :ok
    end
  end

  defp attempt_force_redeploy(%Task{} = task) do
    Logger.info(
      "Reconciler: task #{task.id} service #{task.runner_handle} " <>
        "has zero runnable tasks; attempting force-redeploy"
    )

    case Swarm.TaskService.force_redeploy(task.runner_handle) do
      :ok ->
        if wait_for_runnable(task.runner_handle, @redeploy_wait_ms) do
          Logger.info(
            "Reconciler: task #{task.id} service #{task.runner_handle} " <>
              "rescheduled by force-redeploy"
          )
        else
          mark_runner_lost(
            task,
            "force-redeploy did not yield a runnable task within " <>
              "#{@redeploy_wait_ms}ms (constraint likely unsatisfiable)"
          )
        end

      {:error, :not_found} ->
        mark_runner_lost(task, "service returned 404 to force-redeploy")

      {:error, reason} ->
        Logger.warning(
          "Reconciler: force-redeploy failed for task #{task.id}: " <>
            "#{inspect(reason)}; will retry next tick"
        )
    end
  end

  defp wait_for_runnable(_service_id, remaining_ms) when remaining_ms <= 0, do: false

  defp wait_for_runnable(service_id, remaining_ms) do
    case list_runnable_swarm_tasks(service_id) do
      {:ok, [_ | _]} ->
        true

      _ ->
        step = min(@redeploy_poll_ms, remaining_ms)
        Process.sleep(step)
        wait_for_runnable(service_id, remaining_ms - step)
    end
  end

  defp mark_runner_lost(%Task{} = task, reason) do
    Logger.warning(
      "Reconciler: task #{task.id} runner_handle " <>
        "#{task.runner_handle} treated as lost (#{reason}); " <>
        "marking task as error and clearing runner_handle"
    )

    updated = Ash.update!(task, %{}, action: :mark_runner_lost)
    broadcast_task_update(updated)
  end

  defp broadcast_task_update(%Task{id: id} = task) do
    Phoenix.PubSub.broadcast(
      Camelot.PubSub,
      "task:#{id}",
      {:task_updated, task}
    )

    Phoenix.PubSub.broadcast(
      Camelot.PubSub,
      "board",
      {:task_updated, task}
    )
  end

  defp probe_runner(handle) do
    if Runner.backend() == Swarm do
      probe_swarm_service(handle)
    else
      probe_engine_container(handle)
    end
  end

  # Distinguish the recoverable case (service still exists in the
  # swarm catalog but has zero runnable tasks — fixable with
  # force-redeploy) from the terminal case (service truly gone),
  # so the orphan sweep can self-heal transient node partitions
  # before falling back to marking the task as error.
  defp probe_swarm_service(id) do
    case Req.get(DockerApi.request(), url: "/services/#{id}") do
      {:ok, %Req.Response{status: 200}} ->
        case list_runnable_swarm_tasks(id) do
          {:ok, [_ | _]} -> :present
          {:ok, []} -> :no_tasks
          _ -> :unknown
        end

      {:ok, %Req.Response{status: 404}} ->
        :gone

      _ ->
        :unknown
    end
  rescue
    _ -> :unknown
  end

  defp list_runnable_swarm_tasks(service_id) do
    case Req.get(DockerApi.request(),
           url: "/tasks",
           params: [
             filters: ~s({"service":["#{service_id}"],"desired-state":["running"]})
           ]
         ) do
      {:ok, %Req.Response{status: 200, body: tasks}} when is_list(tasks) ->
        {:ok, tasks}

      _ ->
        :error
    end
  end

  defp probe_engine_container(id) do
    case Req.get(DockerApi.request(), url: "/containers/#{id}/json") do
      {:ok, %Req.Response{status: 200}} -> :present
      {:ok, %Req.Response{status: 404}} -> :gone
      _ -> :unknown
    end
  rescue
    _ -> :unknown
  end

  defp delete_by_name(name) do
    if Runner.backend() == Swarm do
      Req.delete(DockerApi.request(), url: "/services/#{name}")
    else
      Req.delete(DockerApi.request(), url: "/containers/#{name}", params: [force: true, v: true])
    end

    :ok
  rescue
    _ -> :ok
  end
end
