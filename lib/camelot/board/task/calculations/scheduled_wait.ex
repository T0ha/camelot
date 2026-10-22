defmodule Camelot.Board.Task.Calculations.ScheduledWait do
  @moduledoc """
  Exposes what usage-aware scheduling would do with each queued card
  right now, for the board and task-page badges:

    * `%{reason: :cap | :window | :start_at, until: DateTime.t(), flag: nil}`
      — held back until `until`;
    * `%{reason: nil, until: nil, flag: :promoted | :at_risk | :reserve_risk}`
      — dispatched, but out of the ordinary;
    * `nil` — nothing applies, or the card is not queued.

  Batched: one `Camelot.Scheduling.Planner.decide_all/2` call for the
  whole record list, the same one the dispatcher makes, so the badge
  can never disagree with what dispatch does.
  """
  use Ash.Resource.Calculation

  alias Camelot.Scheduling.Planner

  @impl true
  @spec load(Ash.Query.t(), keyword(), map()) :: list()
  def load(_query, _opts, _context) do
    [
      :state,
      :stage,
      :priority,
      :creator_id,
      :agent_id,
      :weekly_cap_override,
      :windows_override,
      :ignore_limits,
      :start_at,
      :deadline_at
    ]
  end

  @impl true
  @spec calculate([Ash.Resource.record()], keyword(), map()) :: [map() | nil]
  def calculate(tasks, _opts, _context) do
    now = DateTime.utc_now()
    {queued, _others} = Enum.split_with(tasks, &(&1.state == :queued))

    decisions =
      queued
      |> Planner.decide_all(now)
      |> Map.new(fn {task, decision} -> {task.id, decision} end)

    Enum.map(tasks, &badge(Map.get(decisions, &1.id)))
  end

  defp badge({:wait, reason, until}), do: %{reason: reason, until: until, flag: nil}
  defp badge({:run, flag}), do: %{reason: nil, until: nil, flag: flag}
  defp badge(_run_or_nil), do: nil
end
