defmodule Camelot.Board.Changes.DispatchTasks do
  @moduledoc """
  Ash generic action implementation that scans dispatchable
  tasks and dispatches all of them, highest priority first.

  Concurrency is bounded independently by `Camelot.Runtime.RunnerPool`
  (keyed by task creator), not by this dispatcher — a task's agent CLI
  is fixed at creation time, so there's no per-agent idle/busy slot to
  gate on anymore. `RunnerPool` never refuses a dispatch; it queues.
  """
  use Ash.Resource.Actions.Implementation

  alias Camelot.Accounts.Credential
  alias Camelot.Board.PromptBuilder
  alias Camelot.Board.Task
  alias Camelot.Board.UsageLimitPause
  alias Camelot.Runtime.TaskRegistry
  alias Camelot.Runtime.TaskRunner
  alias Camelot.Runtime.TaskRunnerSupervisor

  require Ash.Query
  require Logger

  @dispatchable_stages [:todo, :planning, :executing, :pr]

  @impl true
  @spec run(
          Ash.ActionInput.t(),
          keyword(),
          Ash.Resource.Actions.Implementation.Context.t()
        ) :: :ok
  def run(_input, _opts, _context) do
    UsageLimitPause.resume_due(DateTime.utc_now())
    Enum.each(dispatchable_tasks(), &dispatch_task/1)
    :ok
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
