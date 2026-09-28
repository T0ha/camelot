defmodule Camelot.Board.TaskLink.Validations.NoSelfLink do
  @moduledoc """
  Rejects a `TaskLink` whose source and target are the same task.

  A task cannot block, parent, or relate to itself — every gating
  aggregate on `Camelot.Board.Task` assumes `source_task_id` and
  `target_task_id` name two distinct tasks.
  """
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    source_id = Ash.Changeset.get_attribute(changeset, :source_task_id)
    target_id = Ash.Changeset.get_attribute(changeset, :target_task_id)

    case {source_id, target_id} do
      {same, same} when not is_nil(same) ->
        {:error, field: :target_task_id, message: "a task cannot link to itself"}

      _ ->
        :ok
    end
  end

  @impl true
  def describe(_opts) do
    [message: "a task cannot link to itself", vars: []]
  end
end
