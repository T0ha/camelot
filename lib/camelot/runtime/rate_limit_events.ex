defmodule Camelot.Runtime.RateLimitEvents do
  @moduledoc """
  Reads the Claude CLI's `rate_limit_event` lines out of a run's JSONL
  output.

  Every event since ~September 2026 carries
  `rate_limit_info.unifiedWindows` — the account's live utilisation of
  its `seven_day` and `five_hour` windows — on `allowed`,
  `allowed_warning` and `rejected` alike:

      "unifiedWindows": {
        "five_hour": {"resetsAt": 1792578000, "utilization": 0},
        "seven_day": {"resetsAt": 1792904400, "utilization": 0.23}
      }

  Older CLIs send only the top-level `rateLimitType`/`resetsAt`, which
  says nothing about how much of the week is used, so they yield no
  windows at all rather than a guess.

  Pure: the buffer in, plain maps out. `Camelot.Agents.UsageSnapshots`
  persists them and `Camelot.Runtime.UsageLimit` reads the same last
  event for hard rejections.
  """

  alias Camelot.Runtime.OutputParser

  @type window :: %{
          window: :weekly | :session,
          used_percent: float(),
          resets_at: DateTime.t()
        }

  # Claude's names → ours. `:session` is the five-hour window a
  # session cap could be built on later.
  @windows [{"seven_day", :weekly}, {"five_hour", :session}]

  @doc """
  The last `rate_limit_event` in `buffer`, or `nil`.

  The last rather than the first: a run that got rejected and then
  recovered mid-run would otherwise read as still limited, and the
  latest utilisation is the one closest to now.
  """
  @spec last_event(String.t()) :: map() | nil
  def last_event(buffer) do
    buffer
    |> OutputParser.jsonl_events()
    |> Enum.filter(&(&1["type"] == "rate_limit_event"))
    |> List.last()
  end

  @doc """
  The weekly and session utilisation reported by the last
  `rate_limit_event` in `buffer`, as percentages (0..100). Empty when
  the run sent none, or only the pre-`unifiedWindows` shape.
  """
  @spec claude_windows(String.t()) :: [window()]
  def claude_windows(buffer) do
    buffer
    |> last_event()
    |> unified_windows()
    |> to_windows()
  end

  defp unified_windows(%{"rate_limit_info" => %{"unifiedWindows" => %{} = windows}}), do: windows
  defp unified_windows(_event), do: %{}

  defp to_windows(unified) do
    Enum.flat_map(@windows, fn {name, window} ->
      unified
      |> Map.get(name)
      |> to_window(window)
    end)
  end

  defp to_window(%{"utilization" => utilization, "resetsAt" => resets_at}, window)
       when is_number(utilization) and is_integer(resets_at) do
    [%{window: window, used_percent: to_percent(utilization), resets_at: DateTime.from_unix!(resets_at)}]
  end

  defp to_window(_entry, _window), do: []

  # `utilization` is a 0..1 fraction; a rejected run can report a hair
  # over 1.
  defp to_percent(utilization) do
    (utilization * 100.0)
    |> min(100.0)
    |> max(0.0)
    |> Float.round(2)
  end
end
