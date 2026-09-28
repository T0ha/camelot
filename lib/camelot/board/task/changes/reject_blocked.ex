defmodule Camelot.Board.Task.Changes.RejectBlocked do
  @moduledoc """
  Refuses `begin_work` for a task whose `blocked?` calculation is true,
  so a manual Retry/Reset cannot jump the gate that the dispatcher's
  `not blocked?` query filter enforces.

  Runs as a `before_action` hook rather than a `validate` because a
  plain validation cannot see aggregates or calculations. The already
  loaded value on the changeset data is reused when present — every
  caller that reads a task through `Camelot.Board.Task.link_load/0`
  (the dispatcher and `CamelotWeb.TaskLive`) has it, so the common
  path costs no extra round trip.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &reject_blocked/1)
  end

  defp reject_blocked(changeset) do
    changeset.data
    |> ensure_loaded()
    |> add_blocked_error(changeset)
  end

  defp ensure_loaded(%{blocked?: true} = task), do: task
  defp ensure_loaded(%{blocked?: false} = task), do: task
  defp ensure_loaded(task), do: Ash.load!(task, :blocked?, authorize?: false)

  defp add_blocked_error(%{blocked?: true}, changeset) do
    Ash.Changeset.add_error(changeset,
      field: :base,
      message: "task is blocked by an incomplete dependency"
    )
  end

  defp add_blocked_error(_task, changeset), do: changeset
end
