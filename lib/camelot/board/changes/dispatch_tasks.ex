defmodule Camelot.Board.Changes.DispatchTasks do
  @moduledoc """
  Ash generic action implementation that scans dispatchable
  tasks and dispatches all of them, highest priority first.

  Concurrency is bounded independently by `Camelot.Runtime.RunnerPool`
  (keyed by task creator), not by this dispatcher — a task's agent CLI
  is fixed at creation time, so there's no per-agent idle/busy slot to
  gate on anymore. `RunnerPool` never refuses a dispatch; it queues.

  What *is* gated here is usage: `apply_gate/2` runs every candidate
  through `Camelot.Scheduling.Gate` (weekly cap, run windows,
  start-at, deadline) and dispatches the rest in deadline-aware order.
  A held-back card simply stays `:queued` and is looked at again on
  the next tick; nothing already running is ever stopped.
  """
  use Ash.Resource.Actions.Implementation

  alias Camelot.Accounts.Credential
  alias Camelot.Board.PromptBuilder
  alias Camelot.Board.Task
  alias Camelot.Board.UsageLimitPause
  alias Camelot.Cache
  alias Camelot.Runtime.TaskRegistry
  alias Camelot.Runtime.TaskRunner
  alias Camelot.Runtime.TaskRunnerSupervisor
  alias Camelot.Scheduling.Gate
  alias Camelot.Scheduling.Planner
  alias Camelot.Telemetry.Capture

  require Ash.Query
  require Logger

  @dispatchable_stages [:todo, :planning, :executing, :pr]

  # How long the last reported gate reason of a card is remembered, so
  # `task_gated` fires on a change rather than every minute. A miss
  # only re-reports the same reason once.
  @gated_ttl to_timeout(day: 1)

  @impl true
  @spec run(
          Ash.ActionInput.t(),
          keyword(),
          Ash.Resource.Actions.Implementation.Context.t()
        ) :: :ok
  def run(_input, _opts, _context) do
    now = DateTime.utc_now()
    UsageLimitPause.resume_due(now)

    dispatchable_tasks()
    |> apply_gate(now)
    |> Enum.each(&dispatch_task/1)

    :ok
  end

  @doc """
  Drops the cards `Camelot.Scheduling.Gate` holds back at `now` and
  orders the rest for dispatch — deadline-promoted first, then nearest
  deadline, then priority (see `Camelot.Scheduling.Planner.runnable/1`).
  Reports `task_gated` whenever a card's wait reason changes.
  """
  @spec apply_gate([Task.t()], DateTime.t()) :: [Task.t()]
  def apply_gate(tasks, now) do
    decisions = Planner.decide_all(tasks, now)
    Enum.each(decisions, &report_gated/1)
    Planner.runnable(decisions)
  end

  # `project.status == :active` keeps an archived project's tasks out
  # of the dispatch loop the same way `not blocked?` keeps a task
  # waiting on an incomplete dependency out of it — both gates belong
  # in the query, not a post-fetch `Enum.filter`, so a board with many
  # queued tasks isn't paying to load and inspect rows it will discard.
  # The usage-limit gate can't join the same way (the limit lives on a
  # `Credential` keyed by creator+kind, not a column on `Task`), so it
  # runs as a post-fetch reject instead.
  defp dispatchable_tasks do
    Task
    |> Ash.Query.filter(
      state == :queued and stage in ^@dispatchable_stages and not blocked? and
        project.status == :active
    )
    |> Ash.Query.sort(priority: :desc)
    |> Ash.read!(
      load:
        [:blocked?, :messages, :attachments, :project, :agent] ++
          Task.link_load() ++ [creator: [:github_installations]],
      authorize?: false
    )
    |> Enum.reject(&usage_limited?/1)
  end

  defp usage_limited?(%Task{creator_id: creator_id, agent: %{required_credential_kinds: kinds}}) do
    now = DateTime.utc_now()
    Enum.any?(kinds, &credential_limited?(creator_id, &1, now))
  end

  defp usage_limited?(_task), do: false

  defp credential_limited?(creator_id, kind, now) do
    case Credential.for_user_and_kind(creator_id, kind) do
      %Credential{usage_limited_until: %DateTime{} = until} -> DateTime.after?(until, now)
      _ -> false
    end
  end

  @spec report_gated({Task.t(), Gate.decision()}) :: :ok
  defp report_gated({task, decision}) do
    reason = gated_reason(decision)
    key = {:task_gated, task.id}

    case Cache.get(key) do
      {:ok, ^reason} -> :ok
      _changed_or_miss -> remember_gated(key, task, reason)
    end
  end

  defp remember_gated(key, task, reason) do
    _ = Cache.put(key, reason, ttl: @gated_ttl)
    capture_gated(task, reason)
  end

  # A card that was never gated and still is not is not news.
  defp capture_gated(_task, :none), do: :ok

  defp capture_gated(task, reason) do
    Capture.capture("task_gated", task.creator_id, %{data_id: task.id, reason: reason})
  end

  defp gated_reason({:wait, reason, _until}), do: reason
  defp gated_reason({:run, flag}), do: flag
  defp gated_reason(:run), do: :none

  defp dispatch_task(task) do
    case Ash.update(task, %{}, action: :begin_work) do
      {:ok, task} ->
        broadcast_task_update(task)
        ensure_task_runner(task.id)
        prompt = PromptBuilder.build(task)

        case TaskRunner.dispatch(task.id, prompt, task.allowed_tools || []) do
          :ok ->
            Logger.info("Dispatched task #{task.id}")

          {:error, reason} ->
            Logger.warning(
              "Failed to dispatch task #{task.id}: " <>
                "#{inspect(reason)}"
            )
        end

      {:error, error} ->
        Logger.warning(
          "Failed to begin work on task #{task.id}: " <>
            "#{inspect(error)}"
        )
    end
  end

  defp ensure_task_runner(task_id) do
    case TaskRegistry.lookup(task_id) do
      nil -> TaskRunnerSupervisor.start_task_runner(task_id)
      _pid -> :ok
    end
  end

  defp broadcast_task_update(task) do
    Phoenix.PubSub.broadcast(
      Camelot.PubSub,
      "board",
      {:task_updated, task}
    )

    Phoenix.PubSub.broadcast(
      Camelot.PubSub,
      "task:#{task.id}",
      {:task_updated, task}
    )
  end
end
