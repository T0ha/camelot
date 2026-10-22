defmodule Camelot.Board.Task.Changes.ImplyIgnoreLimits do
  @moduledoc """
  Pinning a card to a start time or a deadline means "run it then",
  so it also sets `ignore_limits` — unless the caller sent
  `ignore_limits` explicitly, in which case their choice stands (the
  schedule form's "run even if over limits" select).

  Only a start or deadline being *set* triggers it; editing another
  field of an already-pinned card leaves the flag alone.
  """
  use Ash.Resource.Change

  @impl true
  @spec change(Ash.Changeset.t(), keyword(), Ash.Resource.Change.Context.t()) ::
          Ash.Changeset.t()
  def change(changeset, _opts, _context) do
    imply(changeset, pinning?(changeset) and not explicit?(changeset))
  end

  defp imply(changeset, true), do: Ash.Changeset.force_change_attribute(changeset, :ignore_limits, true)
  defp imply(changeset, false), do: changeset

  defp pinning?(changeset) do
    Enum.any?([:start_at, :deadline_at], &set?(changeset, &1))
  end

  defp set?(changeset, field) do
    Ash.Changeset.changing_attribute?(changeset, field) and
      not is_nil(Ash.Changeset.get_attribute(changeset, field))
  end

  defp explicit?(%Ash.Changeset{params: params}) do
    Map.has_key?(params, :ignore_limits) or Map.has_key?(params, "ignore_limits")
  end
end
