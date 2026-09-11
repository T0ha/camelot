defmodule Camelot.Runtime.Reconciler do
  @moduledoc """
  Reconciles persistent session state in PostgreSQL
  with the live Docker/Swarm reality, both at boot and
  periodically (every minute).

  On boot, in this order:

    1. Re-resolves every floating-tag runner image to the
       newest published digest. This runs **before**
       anything else, because it *replaces containers*: a
       task whose container was rolled has its in-flight
       sessions failed and is re-queued immediately, rather
       than being handed to an adoption that would poll for
       a completion marker the new container can never
       write.
    2. Recovers any `Session{status: :running}` rows whose
       owning TaskRunner is gone (e.g. after a redeploy).
       If the session's task runner container is still
       alive, it is **adopted** — a fresh TaskRunner
       re-attaches and finalises from the durable tee'd
       output (`was_adopted` is set). Adoption is refused
       when the live container was *replaced* after the
       session's exec began (Swarm reschedule / OOM): the
       tee'd output and completion marker lived in the prior
       container's `/tmp` and can never reappear, so polling
       for them would hang forever — such a session is
       failed instead. When there is no live container to
       re-attach to (bootstrap sessions, the LocalPort
       backend, or a truly gone runner) the session is
       likewise marked failed for the user to retry.
    3. Recovers `Session{status: :queued}` rows orphaned by
       the restart. `RunnerPool` rebuilds its queue purely
       in memory, so such a row has no owner left to grant
       it a slot and would otherwise sit queued forever with
       its task stuck `:in_progress`.
    4. Sweeps orphan `camelot-runner-*` services that no
       longer have a `:queued` or `:running` session row.
    5. Sweeps tasks whose `runner_handle` points to a
       stale backend service (node partition, manual
       `docker service rm`, swarm reschedule failure).
       For Swarm services that still exist but have zero
       runnable tasks, triggers a `force-redeploy` (bumps
       `Spec.TaskTemplate.ForceUpdate`) so the swarm
       reschedules without losing the service identity.
       Only after the redeploy fails to yield a runnable
       task within `redeploy_wait_ms` — measured across
       ticks, never by sleeping in this process — or when
       the service is genuinely 404, is the runner treated
       as lost. A 15-minute grace on `updated_at` keeps
       in-flight dispatches from being false-positives.

  Every recovery above goes through
  `Camelot.Board.Interruption`, which **re-queues** the task
  rather than erroring it: the work was cut short by
  infrastructure, not by the agent, so the dispatcher simply
  runs it again. Only a task that keeps being interrupted
  without ever completing a run exhausts the re-queue cap and
  lands in `state: :error`.

  In steady state, the same sweep runs every 60s to
  catch any drift Camelot didn't notice (manual
  `docker service rm`, network blips during cleanup,
  etc.).
  """
  use GenServer

  alias Camelot.Agents.Session
  alias Camelot.Board.Interruption
  alias Camelot.Board.Task
  alias Camelot.Runtime.Runner
  alias Camelot.Runtime.Runner.DockerApi
  alias Camelot.Runtime.Runner.LocalPort
  alias Camelot.Runtime.Runner.Spec
  alias Camelot.Runtime.Runner.Swarm
  alias Camelot.Runtime.Runner.Swarm.ExecSession
  alias Camelot.Runtime.RunnerPool
  alias Camelot.Runtime.SecretSync
  alias Camelot.Runtime.SessionRegistry
  alias Camelot.Runtime.TaskRegistry
  alias Camelot.Runtime.TaskRunner
  alias Camelot.Runtime.TaskRunnerSupervisor

  require Ash.Query
  require Logger

  @tick_ms 60_000
  @log_retention_ms 300_000
  @stale_runner_grace_ms 900_000
  # Covers the gap between a session row being created and its owner
  # enqueueing it in `RunnerPool`, so the sweep can't race a dispatch
  # that is only milliseconds old.
  @queued_grace_ms 60_000
  @default_redeploy_wait_ms 60_000
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
    if !skip_initial_tick?(), do: schedule_boot_work(self())
    {:ok, %{redeploys: %{}}}
  end

  # Boot work fires once, `initial_delay_ms` after start (which, in a
  # release, is after `Camelot.Release.migrate` has run — see
  # `rel/overlays/bin/server`).
  #
  # A single message, not two: the image re-pin and the reconcile pass
  # must run in a fixed order. The re-pin *replaces containers*, and the
  # reconcile pass decides which sessions are safe to re-attach to — so
  # re-pinning second would roll containers out from under adoptions
  # that had just been declared healthy, leaving them polling for a
  # completion marker in a container that no longer exists.
  defp schedule_boot_work(pid) do
    Process.send_after(pid, :boot, initial_delay_ms())
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

  # How long a force-redeployed service gets to produce a runnable task
  # before its runner is treated as lost. Configurable because it has to
  # cover a cold image pull, which varies wildly with runner image size.
  defp redeploy_wait_ms do
    :camelot
    |> Application.get_env(:runner, [])
    |> Keyword.get(:redeploy_wait_ms, @default_redeploy_wait_ms)
  end

  @impl GenServer
  def handle_call(:reconcile_now, _from, state) do
    {:reply, :ok, do_reconcile(state)}
  end

  @impl GenServer
  def handle_info(:boot, state) do
    Enum.each(autoupdate_runner_images(), &interrupt_rolled_task/1)
    handle_info(:tick, state)
  end

  def handle_info(:tick, state) do
    state = do_reconcile(state)
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Reconciliation pass ---

  defp do_reconcile(state) do
    fail_stale_running_sessions()
    recover_stale_queued_sessions()

    if backend_available?() do
      sweep_backend(state)
    else
      skip_sweep(state)
    end
  rescue
    e ->
      Logger.warning("Reconciler pass failed: #{Exception.message(e)}")
      state
  end

  defp skip_sweep(state) do
    Logger.debug("Reconciler: backend unavailable, skipping sweep")
    state
  end

  defp sweep_backend(state) do
    live_sessions = list_runner_services()
    sweep_orphan_services(live_sessions)

    live_tasks = list_task_runners()
    sweep_orphan_task_runners(live_tasks)
    state = sweep_stale_task_runner_handles(state)

    if Runner.backend() == Swarm, do: sweep_orphan_github_app_secrets()

    RunnerPool.tick()
    state
  end

  # One-shot boot sweep: re-resolve every Swarm task service whose
  # image uses a floating tag (`latest` or untagged) to the newest
  # published digest, in place. Idempotent — a service already on the
  # current digest is not rolled. Swarm-only; best-effort so a Docker
  # hiccup can't crash the reconciler.
  #
  # Returns the ids of the tasks whose container was actually replaced,
  # so the caller can recover their in-flight sessions before anything
  # tries to adopt them.
  defp autoupdate_runner_images do
    if Runner.backend() == Swarm and backend_available?() do
      sweep_runner_images()
    else
      []
    end
  rescue
    e ->
      Logger.warning("Reconciler autoupdate pass failed: #{Exception.message(e)}")
      []
  end

  defp sweep_runner_images do
    ids = list_task_runners()

    rolled =
      Enum.filter(ids, fn id ->
        Swarm.TaskService.autoupdate_image(Spec.task_runner_name(id)) == :rolled
      end)

    Logger.info(
      "Reconciler: autoupdate swept #{length(ids)} task runner image(s); " <>
        "#{length(rolled)} rolled"
    )

    rolled
  end

  @rolled_reason "the runner container was replaced by a deploy (new runner image)"

  defp interrupt_rolled_task(task_id) do
    # The service is alive and now runs the new image — only its
    # container was replaced — so its handle stays valid.
    recover_interrupted_task(task_id, @rolled_reason, keep_runner_handle: true)
  end

  @doc """
  Recover a task whose in-flight run was cut short by infrastructure.

  A replaced container is a brand new container: the exec-wrapper's
  tee'd output and completion marker lived in the previous one's `/tmp`
  and are gone, so whatever was running can never report its result.
  Its `:queued`/`:running` sessions are failed with `reason` — which
  must happen *before* `fail_stale_running_sessions/0` runs, or one of
  them gets handed to an adoption that polls for 15 minutes — and the
  task is put back in the queue for the dispatcher to run again.

  Best-effort: never raises, so one unrecoverable task can't abort the
  boot sweep.
  """
  @spec recover_interrupted_task(String.t(), String.t(), keyword()) :: :ok
  def recover_interrupted_task(task_id, reason, opts \\ []) do
    task_id
    |> live_sessions_for_task()
    |> Enum.each(&fail_interrupted_session(&1, reason))

    Interruption.requeue_or_error_by_id(task_id, reason, opts)
    :ok
  rescue
    e ->
      Logger.warning(
        "Reconciler: could not recover interrupted task #{task_id}: " <>
          "#{Exception.message(e)}"
      )

      :ok
  end

  defp live_sessions_for_task(task_id) do
    Session
    |> Ash.Query.filter(task_id == ^task_id and status in [:queued, :running])
    |> Ash.read!()
  end

  defp fail_interrupted_session(%Session{} = session, reason) do
    Logger.info("Reconciler: failing session #{session.id} — #{reason}")

    Ash.update!(
      session,
      %{
        error_message:
          "This run was interrupted because #{reason}. " <>
            "The task has been re-queued and will run again.",
        exit_code: 1
      },
      action: :fail
    )
  end

  defp fail_stale_running_sessions do
    Session
    |> Ash.Query.filter(status == :running)
    |> Ash.read!()
    |> Enum.each(&recover_stale_session/1)
  end

  # A `:running` session whose owning TaskRunner is gone (typically
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
        :adopt -> adopt_or_fail(session, handle)
        :fail -> fail_stale_session(session)
      end
    end
  end

  # Even when the runner container is still alive, adopting is pointless
  # if that container was *replaced* since the session's exec began: the
  # completion marker the adoption would poll for lived in the prior
  # container's /tmp and can never appear. Fail such a session (it stays
  # user-recoverable) instead of handing it to an unbounded poll. This is
  # race-free — we are in the branch where the owning TaskRunner is
  # already gone.
  defp adopt_or_fail(%Session{} = session, handle) do
    if doomed_adoption?(container_started_for(handle), session.started_at) do
      Logger.info(
        "Reconciler: not adopting session #{session.id} — runner " <>
          "container was replaced after the exec began; failing it so " <>
          "it can be retried"
      )

      fail_stale_session(session)
    else
      adopt_stale_session(session)
    end
  end

  @doc """
  Whether a would-be adoption is doomed: the runner container was
  replaced after the session's exec began, so the completion marker the
  adoption polls for is gone.
  """
  @spec doomed_adoption?(DateTime.t() | nil, DateTime.t() | nil) :: boolean()
  def doomed_adoption?(container_started_at, session_started_at) do
    ExecSession.container_replaced?(container_started_at, session_started_at)
  end

  # Best-effort start time of the service's live replica, read from the
  # manager task list (no node proxy needed). `nil` on any Swarm error or
  # non-Swarm backend, in which case adoption proceeds and ExecSession's
  # own budget bounds the poll.
  defp container_started_for(handle) when is_binary(handle) do
    if Runner.backend() == Swarm, do: swarm_task_created_at(handle)
  end

  defp container_started_for(_handle), do: nil

  defp swarm_task_created_at(service_id) do
    case list_runnable_swarm_tasks(service_id) do
      {:ok, [_ | _] = tasks} ->
        tasks
        |> Enum.map(&Map.get(&1, "CreatedAt"))
        |> Enum.reject(&is_nil/1)
        |> Enum.flat_map(&parse_datetime/1)
        |> latest_datetime()

      _ ->
        nil
    end
  end

  defp parse_datetime(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> [dt]
      _ -> []
    end
  end

  defp latest_datetime([]), do: nil
  defp latest_datetime([_ | _] = dts), do: Enum.max(dts, DateTime)

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

  defp adopt_stale_session(%Session{task_id: task_id} = session) when is_binary(task_id) do
    Logger.info(
      "Reconciler: adopting running session #{session.id} " <>
        "(runner container still alive)"
    )

    with :ok <- ensure_task_runner(task_id),
         :ok <- TaskRunner.adopt(task_id, session.id) do
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

  defp ensure_task_runner(task_id) do
    case TaskRegistry.lookup(task_id) do
      nil ->
        case TaskRunnerSupervisor.start_task_runner(task_id) do
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
        "(owning TaskRunner not registered, no adoptable runner)"
    )

    Ash.update!(
      session,
      %{
        error_message:
          "TaskRunner unregistered without finalising this session " <>
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

  # `github_app_token` is minted per-task (see
  # `Camelot.Runtime.TaskRunner.maybe_append_github_app_token/3`),
  # not per-user like every other credential, so it needs its own
  # sweep keyed off the task rather than piggybacking on
  # `sweep_orphan_task_runners/1`'s live-service list — the secret can
  # outlive the task's runner container/service.
  defp sweep_orphan_github_app_secrets do
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

    list_github_app_secret_task_ids()
    |> Enum.reject(&MapSet.member?(valid, &1))
    |> Enum.each(fn task_id ->
      Logger.info("Reconciler: removing orphan github_app_token secret for task #{task_id}")
      delete_by_name(SecretSync.task_secret_name(task_id, :github_app_token))
    end)
  end

  @github_app_secret_prefix "camelot_task_"
  @github_app_secret_suffix "_gh_token"

  defp list_github_app_secret_task_ids do
    case Req.get(DockerApi.request(), url: "/secrets") do
      {:ok, %Req.Response{status: 200, body: secrets}} when is_list(secrets) ->
        secrets
        |> Enum.map(&get_in(&1, ["Spec", "Name"]))
        |> Enum.flat_map(&extract_github_app_secret_task_id/1)

      _ ->
        []
    end
  end

  @doc false
  # Extracts the task id from a `camelot_task_<id>_gh_token` Swarm
  # secret name, or `[]` for anything else. List-returning (instead of
  # `nil`/id) so callers can `Enum.flat_map/2` straight over the full
  # secret list. Public (with `@doc false`) so the name parsing is
  # unit-testable without a Docker API.
  @spec extract_github_app_secret_task_id(String.t() | nil) :: [String.t()]
  def extract_github_app_secret_task_id(nil), do: []

  def extract_github_app_secret_task_id(name) do
    with @github_app_secret_prefix <> rest <- name,
         true <- String.ends_with?(rest, @github_app_secret_suffix) do
      [String.trim_trailing(rest, @github_app_secret_suffix)]
    else
      _ -> []
    end
  end

  # Probe per-task (not via bulk list) so a transient Docker API
  # hiccup can't false-positive every in-flight task at once.
  defp sweep_stale_task_runner_handles(state) do
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
    |> Enum.reduce(state, &probe_and_recover/2)
  end

  defp probe_and_recover(%Task{} = task, state) do
    case probe_runner(task.runner_handle) do
      :present -> forget_redeploy(state, task)
      :gone -> mark_runner_lost(state, task, "service returned 404")
      :no_tasks -> await_or_force_redeploy(state, task)
      :unknown -> state
    end
  end

  # A service with zero runnable tasks gets one force-redeploy and then
  # `redeploy_wait_ms` of *wall clock across ticks* to produce a replica.
  # The wait deliberately does not block here: the reconciler is a single
  # GenServer, and sleeping in it stalls every other task's sweep — and a
  # cold image pull can easily outlast any sleep short enough to be safe.
  defp await_or_force_redeploy(state, %Task{} = task) do
    case Map.fetch(state.redeploys, task.id) do
      :error -> force_redeploy(state, task)
      {:ok, issued_at} -> check_redeploy_deadline(state, task, issued_at)
    end
  end

  defp check_redeploy_deadline(state, %Task{} = task, issued_at) do
    elapsed = System.monotonic_time(:millisecond) - issued_at

    if elapsed >= redeploy_wait_ms() do
      mark_runner_lost(
        state,
        task,
        "force-redeploy did not yield a runnable task within " <>
          "#{redeploy_wait_ms()}ms (constraint likely unsatisfiable)"
      )
    else
      Logger.debug(
        "Reconciler: task #{task.id} still has no runnable task " <>
          "#{elapsed}ms after force-redeploy; waiting"
      )

      state
    end
  end

  defp force_redeploy(state, %Task{} = task) do
    Logger.info(
      "Reconciler: task #{task.id} service #{task.runner_handle} " <>
        "has zero runnable tasks; attempting force-redeploy"
    )

    case Swarm.TaskService.force_redeploy(task.runner_handle) do
      :ok ->
        put_in(state.redeploys[task.id], System.monotonic_time(:millisecond))

      {:error, :not_found} ->
        mark_runner_lost(state, task, "service returned 404 to force-redeploy")

      {:error, reason} ->
        Logger.warning(
          "Reconciler: force-redeploy failed for task #{task.id}: " <>
            "#{inspect(reason)}; will retry next tick"
        )

        state
    end
  end

  defp forget_redeploy(state, %Task{id: id}) do
    update_in(state.redeploys, &Map.delete(&1, id))
  end

  # The runner is unusable and cannot be revived. Recover rather than
  # error: the task itself is fine, so re-queue it and let the dispatcher
  # build a fresh runner. `Interruption` errors it only once the re-queue
  # cap shows the task can never actually run.
  defp mark_runner_lost(state, %Task{} = task, reason) do
    Logger.warning(
      "Reconciler: task #{task.id} runner_handle " <>
        "#{task.runner_handle} treated as lost (#{reason}); " <>
        "re-queueing the task with a fresh runner"
    )

    recover_interrupted_task(task.id, "the runner was lost (#{reason})")
    forget_redeploy(state, task)
  end

  @doc """
  Recover sessions left `:queued` with nobody to dispatch them.

  Such a row is never adopted (adoption only looks at `:running`) and
  never drained: `RunnerPool` rebuilds its queue purely in memory, so
  after a restart the row has no owner to grant it a slot and its task
  sits `:in_progress` forever.

  A session queued *legitimately* — waiting its turn behind the per-user
  cap — looks identical in the DB, so it is excluded on liveness, not on
  age: the pool is still tracking it (and there is no `SessionRegistry`
  entry, which is only written once a slot is granted *and* the runner
  has started). The `queued_at` grace covers the gap between creating the
  row and enqueueing it.
  """
  @spec recover_stale_queued_sessions() :: :ok
  def recover_stale_queued_sessions do
    cutoff = DateTime.add(DateTime.utc_now(), -@queued_grace_ms, :millisecond)

    Session
    |> Ash.Query.filter(
      status == :queued and not is_nil(task_id) and
        (is_nil(queued_at) or queued_at < ^cutoff)
    )
    |> Ash.read!()
    |> Enum.reject(&owned_queued_session?/1)
    |> Enum.each(&recover_orphan_queued_session/1)
  end

  defp owned_queued_session?(%Session{id: id} = session) do
    alive_owner?(session) or RunnerPool.tracking?(id)
  end

  defp recover_orphan_queued_session(%Session{} = session) do
    Logger.info(
      "Reconciler: session #{session.id} was left queued by a restart " <>
        "with no owner to dispatch it; re-queueing its task"
    )

    recover_interrupted_task(
      session.task_id,
      "Camelot restarted before this run was dispatched",
      keep_runner_handle: true
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
