defmodule Camelot.Runtime.RateLimitEventsTest do
  use ExUnit.Case, async: true

  alias Camelot.Runtime.RateLimitEvents

  # Shapes captured from Claude CLI stdout (GH#186). Since ~September
  # every `rate_limit_event` carries `unifiedWindows`, including
  # `status: "allowed"`.
  defp event(status, seven_day, five_hour, extra \\ %{}) do
    %{
      "type" => "rate_limit_event",
      "rate_limit_info" =>
        Map.merge(
          %{
            "status" => status,
            "rateLimitType" => "five_hour",
            "resetsAt" => 1_792_578_000,
            "unifiedWindows" => %{
              "five_hour" => five_hour,
              "seven_day" => seven_day
            }
          },
          extra
        )
    }
  end

  defp buffer(events), do: Enum.map_join(events, "\n", &Jason.encode!/1)

  describe "claude_windows/1" do
    test "maps seven_day to :weekly and five_hour to :session" do
      buf =
        buffer([
          %{"type" => "system", "subtype" => "init"},
          event(
            "allowed",
            %{"resetsAt" => 1_792_904_400, "utilization" => 0.23},
            %{"resetsAt" => 1_792_578_000, "utilization" => 0}
          ),
          %{"type" => "result", "result" => "done"}
        ])

      assert [
               %{window: :weekly, used_percent: 23.0, resets_at: weekly_reset},
               %{window: :session, used_percent: +0.0, resets_at: session_reset}
             ] = RateLimitEvents.claude_windows(buf)

      assert weekly_reset == DateTime.from_unix!(1_792_904_400)
      assert session_reset == DateTime.from_unix!(1_792_578_000)
    end

    test "reads allowed_warning and rejected events the same way" do
      warning =
        event(
          "allowed_warning",
          %{"resetsAt" => 1_792_904_400, "utilization" => 0.91},
          %{"resetsAt" => 1_792_578_000, "utilization" => 0.4},
          %{"surpassedThreshold" => 0.9}
        )

      assert [%{window: :weekly, used_percent: 91.0} | _] =
               RateLimitEvents.claude_windows(buffer([warning]))

      rejected =
        event(
          "rejected",
          %{"resetsAt" => 1_792_904_400, "utilization" => 1.0},
          %{"resetsAt" => 1_792_578_000, "utilization" => 0.5}
        )

      assert [%{window: :weekly, used_percent: 100.0} | _] =
               RateLimitEvents.claude_windows(buffer([rejected]))
    end

    test "the last event in the run wins" do
      buf =
        buffer([
          event(
            "allowed",
            %{"resetsAt" => 1_792_904_400, "utilization" => 0.2},
            %{"resetsAt" => 1_792_578_000, "utilization" => 0.1}
          ),
          event(
            "allowed",
            %{"resetsAt" => 1_792_904_400, "utilization" => 0.25},
            %{"resetsAt" => 1_792_578_000, "utilization" => 0.3}
          )
        ])

      assert [%{window: :weekly, used_percent: 25.0}, %{window: :session, used_percent: 30.0}] =
               RateLimitEvents.claude_windows(buf)
    end

    test "utilization above 1 is clamped to 100%" do
      buf =
        buffer([event("rejected", %{"resetsAt" => 1_792_904_400, "utilization" => 1.07}, nil)])

      assert [%{window: :weekly, used_percent: 100.0}] = RateLimitEvents.claude_windows(buf)
    end

    test "an older CLI that sends only the top-level fields yields no windows" do
      old = %{
        "type" => "rate_limit_event",
        "rate_limit_info" => %{
          "status" => "allowed",
          "rateLimitType" => "five_hour",
          "resetsAt" => 1_792_578_000
        }
      }

      assert RateLimitEvents.claude_windows(buffer([old])) == []
    end

    test "a buffer with no rate_limit_event yields no windows" do
      assert RateLimitEvents.claude_windows(buffer([%{"type" => "result"}])) == []
      assert RateLimitEvents.claude_windows("") == []
    end

    test "a malformed window entry is skipped, not raised on" do
      buf =
        buffer([
          event(
            "allowed",
            %{"resetsAt" => "soon", "utilization" => 0.2},
            %{"resetsAt" => 1_792_578_000, "utilization" => 0.1}
          )
        ])

      assert [%{window: :session}] = RateLimitEvents.claude_windows(buf)
    end
  end

  describe "last_event/1" do
    test "returns the last rate_limit_event, or nil" do
      first = event("allowed", nil, nil)
      last = event("rejected", nil, nil)

      assert RateLimitEvents.last_event(buffer([first, last])) == last
      assert RateLimitEvents.last_event(buffer([%{"type" => "result"}])) == nil
    end
  end
end
