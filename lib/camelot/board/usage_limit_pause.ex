defmodule Camelot.Board.UsageLimitPause do
  @moduledoc """
  Recovery policy for a run that failed because the provider's usage
  limit was hit, rather than anything wrong with the task itself.

  The limit lives on the credential (API token), not the task — every
  other queued task for the same user+credential-kind would fail
  identically within seconds of being dispatched. So instead of
  `Camelot.Runtime.TaskRunner`'s normal retry-then-error path, the
  failing task (and every queued sibling on the same credential) is
  paused until the provider's reset time passes, then automatically
  resumed by the next `dispatch_tasks` tick (or immediately via
  `resume_now/1`, the UI's manual override).

  Unlike `Camelot.Board.Interruption` there is no retry cap: a token
  that's still limited on the next attempt simply pauses again.
  """

  alias Camelot.Accounts.Credential
  alias Camelot.Board.Task
  alias Camelot.Board.Workers.SendUsageLimitEmail
  alias Camelot.Runtime.UsageLimit

  require Ash.Query
  require Logger

  @doc """
  Pauses `task_id` after a usage-limit rejection from `kind`'s
  provider. When the task's creator has a `Credential` row for that
  kind, it is marked usage-limited and every other `:queued` task of
  theirs whose agent requires the same kind is paused too; a token
  supplied only via env var (no `Credential` row) pauses just this
  one task. Either way, one pause email is enqueued for the owner.
  """
  @spec pause(String.t(), atom(), UsageLimit.info()) :: :ok
  def pause(task_id, kind, %{reset_at: reset_at, window: window}) do
    task = Ash.get!(Task, task_id, authorize?: false)
    reason = pause_reason(window, reset_at)

    case Credential.for_user_and_kind(task.creator_id, kind) do
      nil ->
        pause_task(task, reset_at, reason)

      credential ->
        mark_credential_limited(credential, reset_at, window)
        task |> sibling_tasks(kind) |> Enum.each(&pause_task(&1, reset_at, reason))
        pause_task(task, reset_at, reason)
    end

    enqueue_email(task.creator_id, window, :paused)
    :ok
  end

  @doc """
  Clears every credential whose usage-limit window has passed and
  resumes every task paused on it. Called at the start of every
  `dispatch_tasks` tick, so paused work self-heals even across an
  app restart.
  """
  @spec resume_due(DateTime.t()) :: :ok
  def resume_due(now) do
    clear_due_credentials(now)
    resume_due_tasks(now)
  end

  @doc """
  Manual "Resume now" override: clears the usage limit on `task`'s
  credential (if any) and immediately resumes it along with every
  other paused sibling on that same credential, instead of waiting
  for `paused_until`/`resume_due/1`.
  """
  @spec resume_now(Task.t()) :: :ok
  def resume_now(%Task{} = task) do
    task = Ash.load!(task, :agent, authorize?: false)
    kind = required_kind(task.agent)
    credential = kind && Credential.for_user_and_kind(task.creator_id, kind)

    if credential do
      clear_credential_limit(credential)
      task |> paused_siblings(kind) |> Enum.each(&resume_task/1)
    end

    resume_task(task)
    :ok
  end

  defp mark_credential_limited(credential, reset_at, window) do
    case Ash.update(
           credential,
           %{usage_limited_until: reset_at, usage_limit_window: window},
           action: :mark_usage_limited
         ) do
      {:ok, _updated} ->
        :ok

      {:error, error} ->
        Logger.warning("Credential #{credential.id}: failed to mark usage-limited: #{inspect(error)}")
    end
  end

  defp clear_credential_limit(credential) do
    case Ash.update(credential, %{}, action: :clear_usage_limit) do
      {:ok, _updated} ->
        :ok

      {:error, error} ->
        Logger.warning("Credential #{credential.id}: failed to clear usage limit: #{inspect(error)}")
    end
  end

  defp clear_due_credentials(now) do
    Credential
    |> Ash.Query.filter(not is_nil(usage_limited_until) and usage_limited_until <= ^now)
    |> Ash.read!(authorize?: false)
    |> Enum.each(&clear_credential_limit/1)
  end

  defp resume_due_tasks(now) do
    Task
    |> Ash.Query.filter(state == :paused and not is_nil(paused_until) and paused_until <= ^now)
    |> Ash.Query.load(:agent)
    |> Ash.read!(authorize?: false)
    |> Enum.reject(&credential_still_limited?/1)
    |> Enum.group_by(& &1.creator_id)
    |> Enum.each(fn {creator_id, tasks} ->
      Enum.each(tasks, &resume_task/1)
      enqueue_email(creator_id, nil, :resumed)
    end)
  end

  # A task's own `paused_until` can lag behind its credential: if the
  # credential gets re-limited (a later `pause/3` call extends
  # `usage_limited_until`) while this task is already `:paused`, its
  # `paused_until` is never refreshed. Resuming it here regardless
  # would dispatch it straight back into the same rejection. Since
  # `clear_due_credentials/1` already ran, any credential still
  # carrying a limit here is genuinely not due yet.
  defp credential_still_limited?(%Task{creator_id: creator_id, agent: agent}) do
    case required_kind(agent) do
      nil -> false
      kind -> match?(%{usage_limited_until: %DateTime{}}, Credential.for_user_and_kind(creator_id, kind))
    end
  end

  defp pause_task(%Task{} = task, reset_at, reason) do
    case Ash.update(
           task,
           %{paused_until: reset_at, pause_reason: reason},
           action: :pause_for_usage_limit
         ) do
      {:ok, updated} ->
        broadcast(updated)

      {:error, error} ->
        Logger.warning("Task #{task.id}: failed to pause for usage limit: #{inspect(error)}")
    end
  end

  defp resume_task(%Task{} = task) do
    case Ash.update(task, %{}, action: :resume_paused) do
      {:ok, updated} ->
        broadcast(updated)

      {:error, error} ->
        Logger.warning("Task #{task.id}: failed to resume from usage-limit pause: #{inspect(error)}")
    end
  end

  # Every other `:queued` task from the same creator whose agent also
  # requires `kind` — small per-user scale, so an in-memory filter
  # after the (indexed) creator_id/state read is simpler than an expr
  # join against the array-typed `required_credential_kinds`.
  defp sibling_tasks(%Task{id: id, creator_id: creator_id}, kind) do
    Task
    |> Ash.Query.filter(creator_id == ^creator_id and state == :queued and id != ^id)
    |> Ash.Query.load(:agent)
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&requires_kind?(&1.agent, kind))
  end

  defp paused_siblings(%Task{id: id, creator_id: creator_id}, kind) do
    Task
    |> Ash.Query.filter(creator_id == ^creator_id and state == :paused and id != ^id)
    |> Ash.Query.load(:agent)
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&requires_kind?(&1.agent, kind))
  end

  defp requires_kind?(%{required_credential_kinds: kinds}, kind), do: kind in kinds
  defp requires_kind?(_agent, _kind), do: false

  defp required_kind(%{required_credential_kinds: [kind | _]}), do: kind
  defp required_kind(_agent), do: nil

  defp pause_reason(nil, reset_at) do
    "Paused: provider usage limit reached. Resumes around #{format_time(reset_at)}."
  end

  defp pause_reason(window, reset_at) do
    "Paused: #{window} usage limit reached. Resumes around #{format_time(reset_at)}."
  end

  defp format_time(%DateTime{} = reset_at) do
    reset_at |> DateTime.truncate(:second) |> DateTime.to_string()
  end

  defp enqueue_email(user_id, window, notice) do
    %{user_id: user_id, kind: to_string(notice), window: window}
    |> SendUsageLimitEmail.new()
    |> Oban.insert()

    :ok
  end

  defp broadcast(%Task{id: id} = task) do
    Phoenix.PubSub.broadcast(Camelot.PubSub, "task:#{id}", {:task_updated, task})
    Phoenix.PubSub.broadcast(Camelot.PubSub, "board", {:task_updated, task})
    :ok
  end
end
