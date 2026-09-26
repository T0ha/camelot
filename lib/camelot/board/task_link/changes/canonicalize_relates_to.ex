defmodule Camelot.Board.TaskLink.Changes.CanonicalizeRelatesTo do
  @moduledoc """
  Orders a `:relates_to` link's `source_task_id`/`target_task_id` so the
  smaller UUID is always `source_task_id`.

  `:relates_to` is symmetric — "A relates to B" and "B relates to A" are
  the same fact. Without a canonical ordering, both directions satisfy
  `unique_link` as two distinct rows, rendering as duplicate chips on
  both tasks. Only `:relates_to` is reordered; `:blocks` and
  `:parent_of` are directional and must keep the order the caller gave.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :link_type) do
      :relates_to -> canonicalize(changeset)
      _link_type -> changeset
    end
  end

  defp canonicalize(changeset) do
    source_id = Ash.Changeset.get_attribute(changeset, :source_task_id)
    target_id = Ash.Changeset.get_attribute(changeset, :target_task_id)

    if source_id && target_id && source_id > target_id do
      changeset
      |> Ash.Changeset.force_change_attribute(:source_task_id, target_id)
      |> Ash.Changeset.force_change_attribute(:target_task_id, source_id)
    else
      changeset
    end
  end
end
