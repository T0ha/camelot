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
  """

  alias Camelot.Runtime.OutputParser

  @type info :: %{reset_at: DateTime.t(), window: String.t() | nil}

  # Padding added to a reset time parsed from the provider, so a
  # dispatch tick landing right at the boundary doesn't re-trigger the
  # same rejection.
  @margin_seconds 120

  # Used when a usage-limit rejection is detected but no reset time
  # could be parsed from it. Overridable via `:camelot, :runner,
  # usage_limit_fallback_minutes` (and `USAGE_LIMIT_FALLBACK_MINUTES`
  # at runtime).
  @default_fallback_minutes 60

  @limit_wording ~r/(hit your .*? limit|usage limit|limit reached)/i
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
        detect_from_message(strip_prefix(message, "claude error: "), now)
    end
  end

  def detect(:codex_jsonl, {:error, message}, _output_buffer, now) do
    detect_from_message(strip_prefix(message, "codex error: "), now)
  end

  def detect(_parser, _parsed, _output_buffer, _now), do: :none

  defp strip_prefix(message, prefix), do: String.replace_prefix(message, prefix, "")

  defp detect_from_message(message, now) do
    if Regex.match?(@limit_wording, message) do
      {:limited, limited_info(parse_relative_wait(message, now), nil, now)}
    else
      :none
    end
  end

  defp limited_info(nil, window, now), do: %{reset_at: fallback_reset_at(now), window: window}

  defp limited_info(%DateTime{} = reset_at, window, _now) do
    %{reset_at: DateTime.add(reset_at, @margin_seconds, :second), window: window}
  end

  defp fallback_reset_at(now), do: DateTime.add(now, fallback_minutes() * 60, :second)

  defp parse_relative_wait(message, now) do
    case Regex.run(@relative_wait, message) do
      [_, "", ""] -> nil
      [_, hours, minutes] -> DateTime.add(now, to_int(hours) * 3600 + to_int(minutes) * 60, :second)
      _ -> nil
    end
  end

  defp to_int(""), do: 0
  defp to_int(nil), do: 0
  defp to_int(digits), do: String.to_integer(digits)

  # The last `rate_limit_event` line in the buffer, rather than the
  # first: a session that got rejected and then recovered mid-run
  # would otherwise read as still limited.
  defp rejected_rate_limit_event(output_buffer) do
    output_buffer
    |> OutputParser.jsonl_events()
    |> Enum.filter(&(&1["type"] == "rate_limit_event"))
    |> List.last()
    |> extract_rejected()
  end

  defp extract_rejected(%{"rate_limit_info" => %{"status" => "rejected"} = info}) do
    {:ok, resets_at(info["resetsAt"]), info["rateLimitType"]}
  end

  defp extract_rejected(_event), do: :none

  defp resets_at(epoch) when is_integer(epoch), do: DateTime.from_unix!(epoch)
  defp resets_at(_epoch), do: nil
end
