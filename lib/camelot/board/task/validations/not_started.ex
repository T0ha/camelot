defmodule Camelot.Board.Task.Validations.NotStarted do
  @moduledoc """
  A card can be edited only until it starts: while it is still
  `:queued` and no session has ever run for it. Guards the primary
  `:update`, which the task page's Edit form uses, so an agent never
  runs against a description that changed under it.
  """
  use Ash.Resource.Validation

  alias Camelot.Agents.Session

  require Ash.Query

  @impl true
  @spec validate(Ash.Changeset.t(), keyword(), map()) :: :ok | {:error, keyword()}
  def validate(changeset, _opts, _context) do
    changeset.data
    |> not_started?()
    |> result()
  end

  @doc """
  Whether `task` has not started yet: `:queued` with no session. A
  card in `:done` or `:cancelled` carries no state and so has started.
  """
  @spec not_started?(%{state: atom() | nil, id: Ecto.UUID.t()}) :: boolean()
  def not_started?(%{state: :queued, id: id}) do
    not (Session
         |> Ash.Query.filter(task_id == ^id)
         |> Ash.exists?(authorize?: false))
  end

  def not_started?(_task), do: false

  defp result(true), do: :ok
  defp result(false), do: {:error, field: :state, message: "can only be edited until it starts"}
end
