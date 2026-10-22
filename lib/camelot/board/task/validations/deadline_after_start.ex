defmodule Camelot.Board.Task.Validations.DeadlineAfterStart do
  @moduledoc """
  A card pinned to both a start and a deadline must be able to run in
  between: `deadline_at` has to fall after `start_at`.
  """
  use Ash.Resource.Validation

  @impl true
  @spec validate(Ash.Changeset.t(), keyword(), map()) :: :ok | {:error, keyword()}
  def validate(changeset, _opts, _context) do
    check(
      Ash.Changeset.get_attribute(changeset, :start_at),
      Ash.Changeset.get_attribute(changeset, :deadline_at)
    )
  end

  defp check(nil, _deadline_at), do: :ok
  defp check(_start_at, nil), do: :ok

  defp check(start_at, deadline_at) do
    case DateTime.compare(deadline_at, start_at) do
      :gt -> :ok
      _not_after -> {:error, field: :deadline_at, message: "must be after the start time"}
    end
  end
end
