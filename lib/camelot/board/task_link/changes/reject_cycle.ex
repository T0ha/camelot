defmodule Camelot.Board.TaskLink.Changes.RejectCycle do
  @moduledoc """
  Rejects a link that would introduce a cycle in the combined
  "wait-for" graph spanning `:blocks` and `:parent_of` links.

  Checking each link type in isolation misses the dangerous case,
  which is mixed: a task can be gated by a `:parent_of` edge and a
  `:blocks` edge at once, and either combination can close a loop
  that neither type closes on its own. So every `:blocks`/`:parent_of`
  link is folded into one graph before checking:

      :blocks(s, t)    ⇒ edge t → s   (target waits on blocker)
      :parent_of(s, t) ⇒ edge s → t   (parent waits on child)
      :relates_to      ⇒ no edge      (never gates, so never deadlocks)

  where an edge `x → y` reads "`x` waits on `y`". The link being
  created is rejected iff `y` (the waited-for node) can already reach
  `x` (the waiting node) through existing edges — i.e. adding `x → y`
  would close a loop.

  Traversal is a plain BFS in Elixir, one `Ash.read!/2` per frontier
  level, run inside `before_action/2` so it shares the create's
  transaction. A recursive CTE would be a single round trip instead of
  O(depth), but raw SQL in a change breaks the pattern every other
  change module in this repo follows, and a board's link graph is at
  most a few hundred edges. Concurrent inserts can still race into a
  cycle; the failure mode is "neither task ever dispatches", which is
  visible on the board — accepted as a known gap.
  """
  use Ash.Resource.Change

  alias Camelot.Board.TaskLink

  require Ash.Query

  @impl true
  @spec change(Ash.Changeset.t(), keyword(), Ash.Resource.Change.context()) ::
          Ash.Changeset.t()
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &check_for_cycle/1)
  end

  defp check_for_cycle(changeset) do
    link_type = Ash.Changeset.get_attribute(changeset, :link_type)
    source_id = Ash.Changeset.get_attribute(changeset, :source_task_id)
    target_id = Ash.Changeset.get_attribute(changeset, :target_task_id)

    case wait_for_edge(link_type, source_id, target_id) do
      nil -> changeset
      {waiting, waited_for} -> reject_if_cycle(changeset, waiting, waited_for)
    end
  end

  # target waits on blocker
  defp wait_for_edge(:blocks, source_id, target_id), do: {target_id, source_id}
  # parent waits on child
  defp wait_for_edge(:parent_of, source_id, target_id), do: {source_id, target_id}
  defp wait_for_edge(:relates_to, _source_id, _target_id), do: nil

  defp reject_if_cycle(changeset, waiting, waited_for) do
    if reaches?([waited_for], MapSet.new([waited_for]), waiting) do
      Ash.Changeset.add_error(changeset,
        field: :target_task_id,
        message: "would create a dependency cycle with an existing link"
      )
    else
      changeset
    end
  end

  defp reaches?([], _visited, _target), do: false

  defp reaches?(frontier, visited, target) do
    next = next_nodes(frontier)

    if MapSet.member?(next, target) do
      true
    else
      fresh = MapSet.difference(next, visited)
      reaches?(MapSet.to_list(fresh), MapSet.union(visited, fresh), target)
    end
  end

  defp next_nodes(frontier) do
    TaskLink
    |> Ash.Query.filter(
      (link_type == :blocks and target_task_id in ^frontier) or
        (link_type == :parent_of and source_task_id in ^frontier)
    )
    |> Ash.read!(authorize?: false)
    |> MapSet.new(&edge_destination/1)
  end

  defp edge_destination(%TaskLink{link_type: :blocks, source_task_id: source_id}), do: source_id
  defp edge_destination(%TaskLink{link_type: :parent_of, target_task_id: target_id}), do: target_id
end
