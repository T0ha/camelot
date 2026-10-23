defmodule Camelot.Scheduling.Windows do
  @moduledoc """
  UTC minute-of-week arithmetic for `Camelot.Agents.RunWindow`s.

  Minute `0` is Monday 00:00 UTC and `10079` Sunday 23:59 UTC. A
  window covers `start_minute` (inclusive) up to `end_minute`
  (exclusive); `end_minute < start_minute` wraps past Sunday into
  Monday. No time zones here — those are `Camelot.TimeZone`'s job.
  """

  alias Camelot.Agents.RunWindow

  @minutes_per_day 24 * 60
  @minutes_per_week 7 * @minutes_per_day

  @doc "The UTC minute of the week `datetime` falls in, seconds dropped."
  @spec minute_of_week(DateTime.t()) :: 0..10_079
  def minute_of_week(%DateTime{} = datetime) do
    utc = DateTime.shift_zone!(datetime, "Etc/UTC")
    (Date.day_of_week(utc) - 1) * @minutes_per_day + utc.hour * 60 + utc.minute
  end

  @doc "Whether `datetime` falls inside any of `windows`."
  @spec inside?([RunWindow.t()], DateTime.t()) :: boolean()
  def inside?(windows, datetime) do
    minute = minute_of_week(datetime)
    Enum.any?(windows, &covers?(&1, minute))
  end

  @doc """
  When the soonest of `windows` next opens after `now`, to the minute,
  or `nil` without windows. A window opening this very minute is
  `now` itself (truncated).
  """
  @spec next_start([RunWindow.t()], DateTime.t()) :: DateTime.t() | nil
  def next_start([], _now), do: nil

  def next_start(windows, now) do
    minute = minute_of_week(now)

    wait =
      windows
      |> Enum.map(&Integer.mod(&1.start_minute - minute, @minutes_per_week))
      |> Enum.min()

    now
    |> DateTime.truncate(:second)
    |> Map.put(:second, 0)
    |> DateTime.add(wait * 60, :second)
  end

  defp covers?(%RunWindow{start_minute: start, end_minute: finish}, minute) do
    covers?(start, finish, minute, compare(start, finish))
  end

  defp covers?(start, finish, minute, :lt), do: minute >= start and minute < finish
  defp covers?(start, finish, minute, :gt), do: minute >= start or minute < finish
  defp covers?(_start, _finish, _minute, :eq), do: false

  defp compare(a, b) when a < b, do: :lt
  defp compare(a, b) when a > b, do: :gt
  defp compare(_a, _b), do: :eq
end
