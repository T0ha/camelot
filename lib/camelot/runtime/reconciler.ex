defmodule Camelot.Runtime.Reconciler do
  @moduledoc """
  Reconciles persistent session state in PostgreSQL
  with the live Docker/Swarm reality, both at boot and
  periodically (every minute).

  On boot:

    1. Marks any `Session{status: :running}` rows as
       failed — the AgentProcess that owned the
       container is gone, and re-attaching a log stream
       safely is left for a follow-up. The session can
       be retried by the user. The `was_adopted` flag on
       Session is reserved for that future watcher.
    2. Queued sessions are *not* touched — their DB rows
       survive untouched, and the next call to
       `RunnerPool.tick/0` (after AgentProcess
       processes restart and re-enqueue) drains them
       normally.
    3. Sweeps orphan `camelot-runner-*` services that no
       longer have a `:queued` or `:running` session row.
    4. Sweeps tasks whose `runner_handle` points to a
       missing backend service (node loss, manual
       `docker service rm`) — marks them as
       `state: :error` and clears `runner_handle` so the
       user can retry. A 15-minute grace on
       `updated_at` keeps in-flight dispatches from
       being false-positives.

  In steady state, the same sweep runs every 60s to
  catch any drift Camelot didn't notice (manual
  `docker service rm`, network blips during cleanup,
  etc.).
  """
  use GenServer

  alias Camelot.Agents.Session
  alias Camelot.Board.Task
  alias Camelot.Runtime.Runner
  alias Camelot.Runtime.Runner.DockerApi
  alias Camelot.Runtime.Runner.Swarm
  alias Camelot.Runtime.RunnerPool
  alias Camelot.Runtime.SessionRegistry

  require Ash.Query
  require Logger

  @tick_ms 60_000
  @log_retention_ms 300_000
  @stale_runner_grace_ms 900_000
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
    |> Enum.each(fn session ->
      if alive_owner?(session) do
        :ok
      else
        Logger.info(
          "Reconciler: failing stale running session #{session.id} " <>
            "(owning AgentProcess not registered)"
        )

        Ash.update!(
          session,
          %{
            error_message:
              "AgentProcess unregistered without finalising this session " <>
                "(likely a crash in finish_session/4). Inspect the runner " <>
                "service `camelot-runner-#{session.id}` for container logs " <>
                "within the retention window.",
            exit_code: 1
          },
          action: :fail
        )
      end
    end)
  end

  defp alive_owner?(%Session{id: id}) do
    case SessionRegistry.lookup(id) do
      pid when is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end
  end

  defp backend_available? do
    backend = Runner.backend()

    if backend == Camelot.Runtime.Runner.LocalPort do
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
      :missing ->
        Logger.warning(
          "Reconciler: task #{task.id} runner_handle " <>
            "#{task.runner_handle} is gone; marking task as " <>
            "error and clearing runner_handle"
        )

        updated = Ash.update!(task, %{}, action: :mark_runner_lost)
        broadcast_task_update(updated)

      _ ->
        :ok
    end
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

  defp probe_swarm_service(id) do
    case Req.get(DockerApi.request(), url: "/services/#{id}") do
      {:ok, %Req.Response{status: 200}} -> :present
      {:ok, %Req.Response{status: 404}} -> :missing
      _ -> :unknown
    end
  rescue
    _ -> :unknown
  end

  defp probe_engine_container(id) do
    case Req.get(DockerApi.request(), url: "/containers/#{id}/json") do
      {:ok, %Req.Response{status: 200}} -> :present
      {:ok, %Req.Response{status: 404}} -> :missing
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
