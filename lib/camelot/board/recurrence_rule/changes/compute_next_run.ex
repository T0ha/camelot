defmodule Camelot.Board.RecurrenceRule.Changes.ComputeNextRun do
  @moduledoc """
  Sets `next_run_at` to the rule's first occurrence after now, via
  `Camelot.Scheduling.Recurrence`.

  Runs as a `before_action`, once the attribute and pattern checks
  have passed. A rule whose first occurrence already lies past its
  `ends_at` is refused rather than saved as a series that can never
  run.
  """
  use Ash.Resource.Change

  alias Camelot.Board.RecurrenceRule.Series
  alias Camelot.Scheduling.Recurrence

  @impl true
  @spec change(Ash.Changeset.t(), keyword(), Ash.Resource.Change.Context.t()) ::
          Ash.Changeset.t()
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &compute/1)
  end

  defp compute(changeset) do
    rule = Series.rule_from_changeset(changeset)

    with {:ok, next} <- Recurrence.next_occurrence(rule, DateTime.utc_now()),
         :ok <- Series.before_end(next, rule.ends_at) do
      Ash.Changeset.force_change_attribute(changeset, :next_run_at, next)
    else
      {:error, :invalid_rule} ->
        Ash.Changeset.add_error(changeset, field: :frequency, message: "never repeats")

      {:error, :past_end} ->
        Ash.Changeset.add_error(changeset, field: :ends_at, message: "is before the first run")
    end
  end
end
