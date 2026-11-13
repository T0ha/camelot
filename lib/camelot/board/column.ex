defmodule Camelot.Board.Column do
  @moduledoc """
  Which board column a card is displayed in.

  The persisted `stage` is a card's real position in the stage/state
  machine. A queued card whose `start_at` is still in the future is
  merely waiting for `Camelot.Scheduling.Gate` to release it, so it is
  shown in `:todo` whatever its next stage is. Once the start time
  passes and the dispatcher runs `begin_work`, it appears in its real
  column. Nothing is persisted here: this is display only.
  """

  @waiting_stages [:todo, :planning, :executing]

  @type card :: %{
          required(:stage) => atom(),
          required(:state) => atom(),
          required(:start_at) => DateTime.t() | nil,
          optional(atom()) => any()
        }

  @doc """
  The stage whose column shows `task`.

  Queued `:todo`/`:planning`/`:executing` cards with a `start_at` after
  `now` are shown in `:todo`; every other card in its own stage.
  """
  @spec stage_for(card(), DateTime.t()) :: atom()
  def stage_for(task, now \\ DateTime.utc_now())

  def stage_for(%{state: :queued, stage: stage, start_at: %DateTime{} = start_at} = task, now)
      when stage in @waiting_stages do
    case DateTime.compare(start_at, now) do
      :gt -> :todo
      _ -> task.stage
    end
  end

  def stage_for(task, _now), do: task.stage

  @doc """
  The earliest future `start_at` among cards that wait for it, or `nil`.
  """
  @spec next_start_at([card()], DateTime.t()) :: DateTime.t() | nil
  def next_start_at(tasks, now \\ DateTime.utc_now()) do
    tasks
    |> Enum.filter(&waiting?(&1, now))
    |> Enum.map(& &1.start_at)
    |> Enum.min(DateTime, fn -> nil end)
  end

  @spec waiting?(card(), DateTime.t()) :: boolean()
  defp waiting?(%{stage: stage} = task, now) do
    stage in @waiting_stages and future_todo?(task, now)
  end

  defp future_todo?(%{state: :queued, start_at: %DateTime{} = start_at}, now) do
    DateTime.after?(start_at, now)
  end

  defp future_todo?(_task, _now), do: false
end
