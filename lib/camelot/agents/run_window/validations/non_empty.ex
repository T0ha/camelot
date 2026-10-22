defmodule Camelot.Agents.RunWindow.Validations.NonEmpty do
  @moduledoc """
  Rejects a `Camelot.Agents.RunWindow` whose start equals its end.

  Such a window is ambiguous — it reads as both "never" and "all
  week" — and an empty window list already means "always allowed".
  """
  use Ash.Resource.Validation

  @impl true
  @spec validate(Ash.Changeset.t(), keyword(), map()) :: :ok | {:error, keyword()}
  def validate(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.get_attribute(:start_minute)
    |> check(Ash.Changeset.get_attribute(changeset, :end_minute))
  end

  defp check(nil, _end_minute), do: :ok

  defp check(minute, minute) do
    {:error, field: :end_minute, message: "must differ from the start"}
  end

  defp check(_start_minute, _end_minute), do: :ok
end
