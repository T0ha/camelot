defmodule Camelot.Board.RecurrenceRule.Changes.SyncUpcomingCard do
  @moduledoc """
  Keeps the series' upcoming card on the rule's `next_run_at`.

  On `:create` the card named by the `task_id` argument joins the
  series (and gives it its project); on `:update` the target is the
  latest card. Either way the card is re-pinned to `next_run_at` only
  while it has not started — a card that already ran, or is running,
  keeps its own schedule. Runs in the rule's transaction, so a card
  that refuses the change rolls the rule back with it.
  """
  use Ash.Resource.Change

  alias Camelot.Board.RecurrenceRule.Series
  alias Camelot.Board.Task
  alias Camelot.Board.Task.Validations.NotStarted

  @impl true
  @spec change(Ash.Changeset.t(), keyword(), Ash.Resource.Change.Context.t()) ::
          Ash.Changeset.t()
  def change(%Ash.Changeset{action_type: :create} = changeset, _opts, _context) do
    task_id = Ash.Changeset.get_argument(changeset, :task_id)

    case Ash.get(Task, task_id, authorize?: false) do
      {:ok, task} ->
        changeset
        |> Ash.Changeset.force_change_attribute(:project_id, task.project_id)
        |> Ash.Changeset.after_action(fn _changeset, rule -> sync(task, rule) end)

      {:error, _reason} ->
        Ash.Changeset.add_error(changeset, field: :task_id, message: "no such task")
    end
  end

  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, rule ->
      case Series.latest_task(rule.id) do
        {:ok, task} -> sync(task, rule)
        {:error, :no_task} -> {:ok, rule}
      end
    end)
  end

  defp sync(task, rule) do
    task
    |> Ash.Changeset.for_update(:set_recurrence, card_attrs(task, rule))
    |> Ash.update(return_notifications?: true, authorize?: false)
    |> case do
      {:ok, _task, notifications} -> {:ok, rule, notifications}
      {:error, error} -> {:error, error}
    end
  end

  defp card_attrs(task, rule) do
    if NotStarted.not_started?(task) do
      %{recurrence_rule_id: rule.id, start_at: rule.next_run_at}
    else
      %{recurrence_rule_id: rule.id}
    end
  end
end
