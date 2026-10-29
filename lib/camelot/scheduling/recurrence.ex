defmodule Camelot.Scheduling.Recurrence do
  @moduledoc """
  When a recurring series (`Camelot.Board.RecurrenceRule`) runs next.

  Pure: a rule and an instant in, the first occurrence strictly after
  that instant out, in UTC.

  Occurrences are **local wall-clock** times in the rule's `time_zone`,
  so "daily at 09:00" stays at 09:00 local across a DST change — unlike
  run windows (`Camelot.TimeZone`), which are fixed in UTC. A local time
  that falls in the spring-forward gap runs at the first instant after
  the gap; one that happens twice in the fall-back overlap runs at its
  first occurrence. The same rules as `Camelot.TimeZone.local_input_to_utc/2`.

  `interval` counts days, weeks or months from the **anchor** — the
  local date the rule was created (`inserted_at`), or the given instant
  for a rule not saved yet. Weeks start on Monday; a monthly
  `day_of_month` past the end of a shorter month falls on its last day.
  """

  @type frequency :: :daily | :weekly | :monthly

  @typedoc "The fields of a `Camelot.Board.RecurrenceRule` this reads."
  @type rule :: %{
          required(:frequency) => frequency(),
          required(:interval) => pos_integer(),
          required(:weekdays) => [1..7] | nil,
          required(:day_of_month) => 1..31 | nil,
          required(:time_of_day) => Time.t(),
          required(:time_zone) => String.t(),
          optional(:inserted_at) => DateTime.t() | nil,
          optional(atom()) => term()
        }

  # How far ahead to look for a matching date: enough for the largest
  # interval the resource allows (99 months) with room to spare.
  @search_days 3_100

  @weekday_names ~w(Mon Tue Wed Thu Fri Sat Sun)

  @doc """
  The first occurrence of `rule` strictly after `after`, in UTC.

  `{:error, :invalid_rule}` for a rule that can never run — a weekly
  rule with no weekdays, a monthly one with no day, a non-positive
  interval or an unknown zone.
  """
  @spec next_occurrence(rule(), DateTime.t()) ::
          {:ok, DateTime.t()} | {:error, :invalid_rule}
  def next_occurrence(%{interval: interval}, _after) when interval < 1 do
    {:error, :invalid_rule}
  end

  def next_occurrence(%{frequency: :weekly, weekdays: days}, _after) when days in [nil, []], do: {:error, :invalid_rule}

  def next_occurrence(%{frequency: :monthly, day_of_month: nil}, _after) do
    {:error, :invalid_rule}
  end

  def next_occurrence(%{frequency: frequency}, _after) when frequency not in [:daily, :weekly, :monthly],
    do: {:error, :invalid_rule}

  def next_occurrence(%{time_of_day: nil}, _after), do: {:error, :invalid_rule}
  def next_occurrence(%{time_zone: nil}, _after), do: {:error, :invalid_rule}
  def next_occurrence(%{interval: nil}, _after), do: {:error, :invalid_rule}

  def next_occurrence(%{time_zone: zone} = rule, %DateTime{} = after_at) do
    case DateTime.shift_zone(after_at, zone) do
      {:ok, local} -> search(rule, after_at, local)
      {:error, _reason} -> {:error, :invalid_rule}
    end
  end

  @doc ~S"""
  A one-line summary of `rule`, e.g.
  `"Repeats weekly Mon, Thu at 09:00"` or
  `"Repeats every 2 months on day 31 at 18:30"`.
  """
  @spec describe(rule()) :: String.t()
  def describe(rule) do
    [
      "Repeats",
      cadence(rule.frequency, rule.interval),
      days(rule),
      "at",
      Calendar.strftime(rule.time_of_day, "%H:%M")
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp search(rule, after_at, local) do
    anchor = anchor_date(rule, local)
    start = DateTime.to_date(local)

    start
    |> Date.range(Date.add(start, @search_days))
    |> Stream.filter(&matches?(rule, &1, anchor))
    |> Stream.map(&to_utc(&1, rule))
    |> Enum.find(&DateTime.after?(&1, after_at))
    |> found()
  end

  defp found(nil), do: {:error, :invalid_rule}
  defp found(%DateTime{} = occurrence), do: {:ok, occurrence}

  defp anchor_date(%{inserted_at: %DateTime{} = inserted_at, time_zone: zone}, _local) do
    inserted_at |> DateTime.shift_zone!(zone) |> DateTime.to_date()
  end

  defp anchor_date(_rule, local), do: DateTime.to_date(local)

  defp matches?(%{frequency: :daily, interval: interval}, date, anchor) do
    on_interval?(Date.diff(date, anchor), interval)
  end

  defp matches?(%{frequency: :weekly} = rule, date, anchor) do
    Date.day_of_week(date) in rule.weekdays and
      on_interval?(div(Date.diff(monday(date), monday(anchor)), 7), rule.interval)
  end

  defp matches?(%{frequency: :monthly} = rule, date, anchor) do
    months = (date.year - anchor.year) * 12 + date.month - anchor.month

    date.day == min(rule.day_of_month, Date.days_in_month(date)) and
      on_interval?(months, rule.interval)
  end

  defp on_interval?(count, interval), do: Integer.mod(count, interval) == 0

  defp monday(date), do: Date.add(date, 1 - Date.day_of_week(date))

  defp to_utc(date, %{time_of_day: time, time_zone: zone}) do
    date
    |> DateTime.new(time, zone)
    |> resolve()
    |> DateTime.shift_zone!("Etc/UTC")
  end

  defp resolve({:ok, datetime}), do: datetime
  defp resolve({:gap, _before, after_gap}), do: after_gap
  defp resolve({:ambiguous, first, _second}), do: first

  defp cadence(:daily, 1), do: "daily"
  defp cadence(:weekly, 1), do: "weekly"
  defp cadence(:monthly, 1), do: "monthly"
  defp cadence(:daily, n), do: "every #{n} days"
  defp cadence(:weekly, n), do: "every #{n} weeks"
  defp cadence(:monthly, n), do: "every #{n} months"

  defp days(%{frequency: :weekly, weekdays: days}) do
    days
    |> Enum.sort()
    |> Enum.map_join(", ", &Enum.at(@weekday_names, &1 - 1))
  end

  defp days(%{frequency: :monthly, day_of_month: day}), do: "on day #{day}"
  defp days(_rule), do: ""
end
