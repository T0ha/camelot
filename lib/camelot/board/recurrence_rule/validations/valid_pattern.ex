defmodule Camelot.Board.RecurrenceRule.Validations.ValidPattern do
  @moduledoc """
  A weekly rule needs at least one weekday, a monthly one a day of the
  month — without them `Camelot.Scheduling.Recurrence` finds no
  occurrence at all.
  """
  use Ash.Resource.Validation

  @impl true
  @spec validate(Ash.Changeset.t(), keyword(), map()) :: :ok | {:error, keyword()}
  def validate(changeset, _opts, _context) do
    check(
      Ash.Changeset.get_attribute(changeset, :frequency),
      Ash.Changeset.get_attribute(changeset, :weekdays),
      Ash.Changeset.get_attribute(changeset, :day_of_month)
    )
  end

  defp check(:weekly, days, _day) when days in [nil, []] do
    {:error, field: :weekdays, message: "pick at least one weekday"}
  end

  defp check(:monthly, _days, nil) do
    {:error, field: :day_of_month, message: "is required for a monthly repeat"}
  end

  defp check(_frequency, _days, _day), do: :ok
end
