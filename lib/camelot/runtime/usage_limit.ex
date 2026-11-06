defmodule Camelot.Runtime.UsageLimit do
  @moduledoc """
  Detects a provider usage-limit rejection inside a failed CLI run.

  A usage limit lives on the *credential* (API token), not the task —
  retrying immediately just reproduces the same rejection seconds
  later, and every other queued task on the same credential would
  fail identically. `Camelot.Board.UsageLimitPause` uses `detect/4` to
  tell that case apart from an ordinary CLI failure, which still goes
  through `Camelot.Runtime.TaskRunner`'s normal retry-then-error path.

  `:claude_code_json` prefers the structured `rate_limit_event` the
  CLI's JSONL stream emits when the API rejects a request as
  over-limit; free-text wording in the error message is a fallback
  for whenever that event is absent. `:codex_jsonl` has no structured
  signal at all yet, so it reads the error message only.

  `:kimi_jsonl` emits no usage or rate-limit events either; it reads
  the CLI's `provider.<code>: <status> <text>` error. The CLI already
  retries a 429 internally (and never retries quota exhaustion), so a
  `provider.rate_limit` reaching Camelot means the retries ran out.
  `provider.auth_error` is a bad key, not a limit. Kimi Code plan
  quotas come back as `provider.api_error: 429` with the wording from
  Kimi's error reference (5-hour, weekly, monthly, credit and Extra
  Usage balance) and never carry a reset time. The 5-hour window
  falls back to `fallback_minutes/0`; the others to a day, since
  checking back hourly would only re-pause (and re-email) for weeks.
  The concurrent request limit is risk control, not a quota, so it
  stays on the normal retry path.

  `estimated?` is true when the reset time is a fallback rather than
  read from the provider — `Camelot.Board.UsageLimitPause` then
  prefers a reset date the user entered for that quota window.
  """

  alias Camelot.Runtime.OutputParser
  alias Camelot.Runtime.RateLimitEvents

  @type info :: %{
          reset_at: DateTime.t(),
          window: String.t() | nil,
          estimated?: boolean()
        }

  # Padding added to a reset time parsed from the provider, so a
  # dispatch tick landing right at the boundary doesn't re-trigger the
  # same rejection.
  @margin_seconds 120

  # Used when a usage-limit rejection is detected but no reset time
  # could be parsed from it. Overridable via `:camelot, :runner,
  # usage_limit_fallback_minutes` (and `USAGE_LIMIT_FALLBACK_MINUTES`
  # at runtime).
  @default_fallback_minutes 60

  # Fallback for limits that won't clear within hours (monthly and
  # weekly quotas, empty balances).
  @long_fallback_minutes 24 * 60

  @limit_wording ~r/(hit your .*? limit|usage limit|limit reached)/i

  # Kimi Code plan quotas, first match wins: `{wording, window,
  # fallback}` where a `:default` fallback is `fallback_minutes/0`.
  @kimi_quotas [
    {~r/reached your 5-hour usage limit/i, "5-hour", :default},
    {~r/reached your weekly \(7-day\) usage limit/i, "weekly", :long},
    {~r/reached your monthly usage limit/i, "monthly", :long},
    {~r/credit balance is insufficient|Extra Usage (balance has run out|limit set)/i, nil, :long}
  ]

  # `provider.rate_limit` plus the quota-exhausted wording kimi-code
  # 2.3.0 itself recognises (and its `exceeded_current_quota_error`
  # code).
  @kimi_limit_wording ~r/(^provider\.rate_limit|exceeded_current_quota_error|exceeded your current (token )?quota|check your account balance|insufficient balance|recharge your account|please recharge|account (is )?in arrears)/i
  @kimi_balance_wording ~r/(quota|balance|recharge|arrears)/i
  @relative_wait ~r/try again in\s*(?:(\d+)\s*h(?:ours?)?)?\s*(?:(\d+)\s*m(?:in(?:ute)?s?)?)?/i

  @doc """
  How long to pause for when a usage-limit rejection carries no
  parsable reset time.
  """
  @spec fallback_minutes() :: pos_integer()
  def fallback_minutes do
    :camelot
    |> Application.get_env(:runner, [])
    |> Keyword.get(:usage_limit_fallback_minutes, @default_fallback_minutes)
  end

  @doc """
  Inspects a failed run's parsed result (and, for `:claude_code_json`,
  the raw output buffer) for a provider usage-limit rejection.

  Only ever called on a failed run — a successful `{:ok, _}` parse (or
  any parser this module doesn't recognise) always resolves to
  `:none`, same as a failure with no limit wording at all.
  """
  @spec detect(OutputParser.parser(), term(), String.t(), DateTime.t()) ::
          {:limited, info()} | :none
  def detect(:claude_code_json, {:error, message}, output_buffer, now) do
    case rejected_rate_limit_event(output_buffer) do
      {:ok, reset_at, window} ->
        {:limited, limited_info(reset_at, window, now)}

      :none ->
        detect_from_message(strip_prefix(message, "claude error: "), @limit_wording, now)
    end
  end

  def detect(:codex_jsonl, {:error, message}, _output_buffer, now) do
    detect_from_message(strip_prefix(message, "codex error: "), @limit_wording, now)
  end

  def detect(:kimi_jsonl, {:error, "kimi error: " <> message}, _output_buffer, now) do
    case Enum.find(@kimi_quotas, fn {wording, _window, _fallback} -> Regex.match?(wording, message) end) do
      {_wording, window, fallback} -> {:limited, estimated_info(window, fallback, now)}
      nil -> detect_kimi_legacy(message, now)
    end
  end

  def detect(_parser, _parsed, _output_buffer, _now), do: :none

  # `provider.rate_limit` keeps the default fallback; balance and
  # quota exhaustion won't clear within the hour.
  defp detect_kimi_legacy(message, now) do
    case {Regex.match?(@kimi_limit_wording, message), Regex.match?(@kimi_balance_wording, message)} do
      {true, true} -> {:limited, estimated_info(nil, :long, now)}
      {true, false} -> {:limited, estimated_info(nil, :default, now)}
      {false, _balance} -> :none
    end
  end

  defp estimated_info(window, fallback, now) do
    %{reset_at: DateTime.add(now, fallback_seconds(fallback), :second), window: window, estimated?: true}
  end

  defp fallback_seconds(:default), do: fallback_minutes() * 60
  defp fallback_seconds(:long), do: @long_fallback_minutes * 60

  defp strip_prefix(message, prefix), do: String.replace_prefix(message, prefix, "")

  defp detect_from_message(message, wording, now) do
    if Regex.match?(wording, message) do
      {:limited, limited_info(parse_relative_wait(message, now), nil, now)}
    else
      :none
    end
  end

  defp limited_info(nil, window, now), do: estimated_info(window, :default, now)

  defp limited_info(%DateTime{} = reset_at, window, _now) do
    %{reset_at: DateTime.add(reset_at, @margin_seconds, :second), window: window, estimated?: false}
  end

  defp parse_relative_wait(message, now) do
    case Regex.run(@relative_wait, message) do
      [_, "", ""] -> nil
      [_, hours, minutes] -> DateTime.add(now, to_int(hours) * 3600 + to_int(minutes) * 60, :second)
      _ -> nil
    end
  end

  defp to_int(""), do: 0
  defp to_int(digits), do: String.to_integer(digits)

  # Only the last `rate_limit_event` counts — see
  # `RateLimitEvents.last_event/1`.
  defp rejected_rate_limit_event(output_buffer) do
    output_buffer
    |> RateLimitEvents.last_event()
    |> extract_rejected()
  end

  defp extract_rejected(%{"rate_limit_info" => %{"status" => "rejected"} = info}) do
    {:ok, resets_at(info["resetsAt"]), info["rateLimitType"]}
  end

  defp extract_rejected(_event), do: :none

  defp resets_at(epoch) when is_integer(epoch), do: DateTime.from_unix!(epoch)
  defp resets_at(_epoch), do: nil
end
