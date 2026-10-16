defmodule Camelot.Runtime.UsageLimitTest do
  use ExUnit.Case, async: true

  alias Camelot.Runtime.UsageLimit

  @now ~U[2026-10-08 12:00:00.000000Z]

  describe "claude_code_json" do
    test "a rejected rate_limit_event wins over free text" do
      resets_at = DateTime.to_unix(~U[2026-10-08 17:00:00Z])

      buffer =
        Enum.join(
          [
            Jason.encode!(%{"type" => "system"}),
            Jason.encode!(%{
              "type" => "rate_limit_event",
              "rate_limit_info" => %{"status" => "rejected", "resetsAt" => resets_at, "rateLimitType" => "5h"}
            }),
            Jason.encode!(%{"type" => "assistant", "message" => %{"content" => [%{"type" => "text", "text" => "error"}]}})
          ],
          "\n"
        )

      parsed = {:error, "claude error: You've hit your 5h limit"}

      assert {:limited, %{reset_at: reset_at, window: "5h"}} =
               UsageLimit.detect(:claude_code_json, parsed, buffer, @now)

      # The margin nudges the reset time a couple of minutes later
      # than the raw `resetsAt` so a dispatch tick landing right on
      # the boundary doesn't immediately get rejected again.
      assert DateTime.after?(reset_at, ~U[2026-10-08 17:00:00Z])
      assert DateTime.diff(reset_at, ~U[2026-10-08 17:00:00Z]) == 120
    end

    test "only the last rate_limit_event counts" do
      buffer =
        Enum.join(
          [
            Jason.encode!(%{
              "type" => "rate_limit_event",
              "rate_limit_info" => %{"status" => "rejected", "resetsAt" => 1_000, "rateLimitType" => "5h"}
            }),
            Jason.encode!(%{"type" => "rate_limit_event", "rate_limit_info" => %{"status" => "allowed"}})
          ],
          "\n"
        )

      parsed = {:error, "claude error: boom"}

      assert UsageLimit.detect(:claude_code_json, parsed, buffer, @now) == :none
    end

    test "falls back to free-text wording when no rate_limit_event is present" do
      parsed = {:error, "claude error: You've hit your usage limit for this plan"}

      assert {:limited, %{reset_at: reset_at, window: nil}} =
               UsageLimit.detect(:claude_code_json, parsed, "", @now)

      assert DateTime.after?(reset_at, @now)
    end

    test "an unknown reset time falls back to the configured number of minutes" do
      previous = Application.get_env(:camelot, :runner, [])
      Application.put_env(:camelot, :runner, Keyword.put(previous, :usage_limit_fallback_minutes, 30))
      on_exit(fn -> Application.put_env(:camelot, :runner, previous) end)

      parsed = {:error, "claude error: limit reached, try again later"}

      assert {:limited, %{reset_at: reset_at}} =
               UsageLimit.detect(:claude_code_json, parsed, "", @now)

      assert DateTime.diff(reset_at, @now) == 30 * 60
    end

    test "a plain error with no limit wording is not a pause" do
      parsed = {:error, "claude error: something else went wrong"}

      assert UsageLimit.detect(:claude_code_json, parsed, "", @now) == :none
    end

    test "a successful run is never flagged" do
      parsed = {:ok, %{result_text: "all good"}}

      assert UsageLimit.detect(:claude_code_json, parsed, "", @now) == :none
    end
  end

  describe "codex_jsonl" do
    test "detects usage-limit wording in the turn.failed error" do
      parsed = {:error, "codex error: You have hit your usage limit. Try again in 2 hours 30 minutes."}

      assert {:limited, %{reset_at: reset_at, window: nil}} =
               UsageLimit.detect(:codex_jsonl, parsed, "", @now)

      assert DateTime.diff(reset_at, @now) == 2 * 3600 + 30 * 60 + 120
    end

    test "falls back when the wait can't be parsed" do
      parsed = {:error, "codex error: usage limit reached"}

      assert {:limited, %{reset_at: reset_at}} =
               UsageLimit.detect(:codex_jsonl, parsed, "", @now)

      assert DateTime.diff(reset_at, @now) == UsageLimit.fallback_minutes() * 60
    end

    test "a plain 429 with no limit wording is not a pause" do
      parsed = {:error, "codex error: request failed with status 429"}

      assert UsageLimit.detect(:codex_jsonl, parsed, "", @now) == :none
    end
  end

  test "an unrecognised parser is never a pause" do
    assert UsageLimit.detect(:raw_text, {:error, "boom"}, "", @now) == :none
  end
end
