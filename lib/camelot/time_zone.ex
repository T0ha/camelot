defmodule Camelot.TimeZone do
  @moduledoc """
  The one place UTC meets a user's time zone.

  Everything Camelot stores is UTC — `start_at`/`deadline_at`, usage
  snapshot reset times, and run windows as UTC minutes of the week
  (`Camelot.Agents.RunWindow`). `Camelot.Accounts.User.time_zone` is
  used only here, to render those values and to read form input back.

  ## Run windows and DST

  The window editor works in local weekday rows
  (`%{days: [1..7], from: "HH:MM", to: "HH:MM"}`, 1 = Monday) and
  converts them at the zone's offset **at save time**. A weekly
  window is therefore fixed in UTC: across a DST change it shifts by
  an hour in local time, and the profile page shows it re-rendered at
  the current offset so the user can re-save. One-off times
  (`start_at`, `deadline_at`) are converted exactly and are
  unaffected.
  """

  alias Camelot.Agents.RunWindow

  @minutes_per_day 24 * 60
  @minutes_per_week 7 * @minutes_per_day

  @typedoc "A local weekday row of the window editor."
  @type row :: %{days: [1..7], from: String.t(), to: String.t()}

  @doc """
  Reads a `datetime-local` input value (`"2026-10-19T14:00"`) entered
  in `zone` as a UTC datetime. Blank is `{:ok, nil}`.

  A local time that occurs twice (DST ends) resolves to the first
  occurrence; one that does not exist (DST starts) to the first
  instant after the gap.
  """
  @spec local_input_to_utc(String.t() | nil, String.t()) ::
          {:ok, DateTime.t() | nil} | {:error, :invalid_datetime}
  def local_input_to_utc(blank, _zone) when blank in [nil, ""], do: {:ok, nil}

  def local_input_to_utc(value, zone) do
    with {:ok, naive} <- parse_local(value) do
      naive
      |> DateTime.from_naive(zone)
      |> resolve()
      |> to_utc()
    end
  end

  @doc "Renders a UTC datetime as a `datetime-local` value in `zone`."
  @spec to_local_input(DateTime.t() | nil, String.t()) :: String.t()
  def to_local_input(nil, _zone), do: ""

  def to_local_input(%DateTime{} = datetime, zone) do
    datetime
    |> DateTime.shift_zone!(zone)
    |> Calendar.strftime("%Y-%m-%dT%H:%M")
  end

  @doc ~S|Human-readable local time, e.g. `"Mon 19 Oct 14:00 CEST"`.|
  @spec format(DateTime.t() | nil, String.t()) :: String.t()
  def format(nil, _zone), do: "—"

  def format(%DateTime{} = datetime, zone) do
    datetime
    |> DateTime.shift_zone!(zone)
    |> Calendar.strftime("%a %d %b %H:%M %Z")
  end

  @doc """
  Converts local weekday rows to UTC `RunWindow`s at `zone`'s offset
  at `now`. Rows without days, or whose from equals to, are dropped; a
  to-time before the from-time runs past midnight.
  """
  @spec rows_to_windows([row()], String.t(), DateTime.t()) :: [RunWindow.t()]
  def rows_to_windows(rows, zone, now) do
    offset = offset_minutes(zone, now)

    for %{days: days, from: from, to: to} <- rows,
        {:ok, from_minute} <- [parse_clock(from)],
        {:ok, to_minute} <- [parse_clock(to)],
        from_minute != to_minute,
        day <- Enum.sort(days) do
      start = (day - 1) * @minutes_per_day + from_minute
      length = Integer.mod(to_minute - from_minute, @minutes_per_day)

      %RunWindow{
        start_minute: Integer.mod(start - offset, @minutes_per_week),
        end_minute: Integer.mod(start + length - offset, @minutes_per_week)
      }
    end
  end

  @doc """
  The inverse of `rows_to_windows/3`: UTC windows as local weekday
  rows at `zone`'s offset at `now`, days that share the same times
  grouped into one row.
  """
  @spec windows_to_rows([RunWindow.t()], String.t(), DateTime.t()) :: [row()]
  def windows_to_rows(windows, zone, now) do
    offset = offset_minutes(zone, now)

    windows
    |> Enum.map(fn %{start_minute: start, end_minute: finish} ->
      local_start = Integer.mod(start + offset, @minutes_per_week)
      local_end = Integer.mod(finish + offset, @minutes_per_week)

      {div(local_start, @minutes_per_day) + 1,
       {format_clock(rem(local_start, @minutes_per_day)), format_clock(rem(local_end, @minutes_per_day))}}
    end)
    |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))
    |> Enum.map(fn {{from, to}, days} -> %{days: Enum.sort(days), from: from, to: to} end)
    |> Enum.sort_by(&{hd(&1.days), &1.from})
  end

  @doc "Every zone name the bundled tz database knows, sorted."
  @spec zones() :: [String.t()]
  def zones, do: Tzdata.zone_list()

  defp parse_local(value) do
    value
    |> pad_seconds()
    |> NaiveDateTime.from_iso8601()
    |> case do
      {:ok, naive} -> {:ok, naive}
      {:error, _reason} -> {:error, :invalid_datetime}
    end
  end

  # `datetime-local` omits seconds unless they are set.
  defp pad_seconds(value) do
    case String.length(value) do
      16 -> value <> ":00"
      _other -> value
    end
  end

  defp resolve({:ok, datetime}), do: {:ok, datetime}
  defp resolve({:ambiguous, first, _second}), do: {:ok, first}
  defp resolve({:gap, _before, after_gap}), do: {:ok, after_gap}
  defp resolve({:error, _reason}), do: {:error, :invalid_datetime}

  defp to_utc({:ok, datetime}) do
    {:ok, datetime |> DateTime.shift_zone!("Etc/UTC") |> DateTime.add(0, :microsecond)}
  end

  defp to_utc(error), do: error

  defp offset_minutes(zone, now) do
    %DateTime{utc_offset: utc, std_offset: std} = DateTime.shift_zone!(now, zone)
    div(utc + std, 60)
  end

  defp parse_clock(clock) do
    case Time.from_iso8601(pad_seconds_clock(clock)) do
      {:ok, time} -> {:ok, time.hour * 60 + time.minute}
      {:error, _reason} -> :error
    end
  end

  defp pad_seconds_clock(clock) when byte_size(clock) == 5, do: clock <> ":00"
  defp pad_seconds_clock(clock), do: to_string(clock)

  defp format_clock(minute) do
    Enum.map_join([div(minute, 60), rem(minute, 60)], ":", &String.pad_leading(Integer.to_string(&1), 2, "0"))
  end
end
