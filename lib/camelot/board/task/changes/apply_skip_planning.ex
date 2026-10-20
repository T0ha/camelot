defmodule Camelot.Board.Task.Changes.ApplySkipPlanning do
  @moduledoc """
  Starts a task straight in execution when `:create` is given
  `skip_planning: true`: `stage: :executing`, `state: :queued`, and the
  description becomes the plan.

  `Camelot.Board.PromptBuilder.prompt_slug/1` already switches to the
  execution prompt whenever `plan` is present, so nothing downstream
  needs to know the planning phase was skipped. A blank description is
  rejected by the action's own `present(:description)` validation
  rather than here.
  """
  use Ash.Resource.Change

  @impl true
  @spec change(Ash.Changeset.t(), keyword(), Ash.Resource.Change.context()) ::
          Ash.Changeset.t()
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.get_argument(:skip_planning)
    |> apply_skip(changeset)
  end

  defp apply_skip(true, changeset) do
    Ash.Changeset.force_change_attributes(changeset, %{
      stage: :executing,
      state: :queued,
      plan: Ash.Changeset.get_attribute(changeset, :description)
    })
  end

  defp apply_skip(_skip?, changeset), do: changeset
end
