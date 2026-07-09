defmodule Camelot.Runtime.OutputParser do
  @moduledoc """
  Parses CLI output based on the parser strategy
  recorded on the agent's template.

  - `:claude_code_json` expects a single JSON object with a
    `result` field plus optional `is_error`, `cost_usd`,
    `duration_ms`, and `permission_denials`.
  - `:raw_text` passes the buffer through unchanged.
  """

  @type parser :: :claude_code_json | :raw_text

  @type permission_denial :: %{
          tool_name: String.t(),
          tool_use_id: String.t(),
          tool_input: map()
        }

  @type parsed :: %{
          result_text: String.t(),
          cost_usd: float() | nil,
          duration_ms: integer() | nil,
          permission_denials: [permission_denial()],
          structured: map() | nil,
          assistant_texts: [String.t()]
        }

  @spec parse(parser(), String.t()) ::
          {:ok, parsed()} | {:error, String.t()}
  def parse(:raw_text, buffer) do
    {:ok,
     %{
       result_text: buffer,
       cost_usd: nil,
       duration_ms: nil,
       permission_denials: [],
       structured: nil,
       assistant_texts: []
     }}
  end

  def parse(:claude_code_json, "") do
    {:error, "empty output"}
  end

  def parse(:claude_code_json, buffer) do
    case extract_json(buffer) do
      {result, objects} -> from_result(result, objects)
      :error -> {:error, "no JSON object found in output"}
    end
  end

  defp from_result(%{"is_error" => true, "result" => message}, _objects) when is_binary(message) do
    {:error, "claude error: " <> message}
  end

  defp from_result(%{"result" => result} = data, objects) do
    denials = parse_denials(data["permission_denials"])
    {result_text, denials} = maybe_extract_plan(result, denials)

    {:ok,
     %{
       result_text: result_text,
       cost_usd: data["cost_usd"] || data["total_cost_usd"],
       duration_ms: data["duration_ms"],
       permission_denials: denials,
       structured: structured_output(data),
       assistant_texts: assistant_texts(objects)
     }}
  end

  defp from_result(_data, _objects), do: {:error, "unexpected JSON structure"}

  # `--json-schema` runs force a `StructuredOutput` tool call; the result
  # event then carries the validated object under `structured_output`
  # (the `result` field holds the same payload as a JSON string).
  defp structured_output(%{"structured_output" => %{} = s}), do: s
  defp structured_output(_), do: nil

  # Every top-level assistant text block, in stream order. The final
  # `result` field is only the LAST assistant turn — often a trailing
  # meta-sentence — so callers that need the full picture (e.g. a plan or
  # a question emitted in an earlier turn) read these instead. Sub-agent
  # turns (non-nil `parent_tool_use_id`) are skipped.
  defp assistant_texts(objects) do
    objects
    |> Enum.filter(&(assistant_event?(&1) and top_level?(&1)))
    |> Enum.flat_map(&text_blocks/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp assistant_event?(%{"type" => "assistant"}), do: true
  defp assistant_event?(_), do: false

  defp text_blocks(%{"message" => %{"content" => content}}) when is_list(content) do
    for %{"type" => "text", "text" => text} <- content, is_binary(text), do: text
  end

  defp text_blocks(_), do: []

  # Tries the whole buffer first (fast path for a single-object
  # `--output-format json` result), then falls back to scanning the
  # per-line objects. Container runners emit entrypoint log lines
  # before the CLI output and terminal escape codes after, so a
  # whole-buffer decode often fails even though valid JSON lines are
  # in there.
  #
  # Returns `{result_object, all_objects}` so callers can read both the
  # chosen result event and every decoded event (for `assistant_texts`).
  defp extract_json(buffer) do
    case Jason.decode(String.trim(buffer)) do
      {:ok, data} -> {data, [data]}
      {:error, _} -> extract_json_from_lines(buffer)
    end
  end

  # `--output-format stream-json` emits one JSON object per line:
  # a system/init event, assistant/tool events, then a final
  # `type: "result"` event carrying the same fields the single-object
  # format uses. Prefer that result event; fall back to the last
  # decodable object so a single-object buffer wrapped in log/terminal
  # noise still parses.
  defp extract_json_from_lines(buffer) do
    objects =
      buffer
      |> String.split(~r/\r?\n/)
      |> Enum.flat_map(&decode_line_to_list/1)

    pick_object(last_result_event(objects), objects)
  end

  # Pair the chosen result object with the full object list; `:error`
  # (no decodable object at all) propagates unchanged.
  defp pick_object(nil, []), do: :error
  defp pick_object(nil, objects), do: {List.last(objects), objects}
  defp pick_object(result, objects), do: {result, objects}

  # A resumed session — the agent yields to a background sub-agent, then
  # wakes on a task-notification — runs as several `claude` invocations
  # concatenated into one log, each emitting its own `type: "result"`
  # event. Every result event is a cumulative snapshot of the session, so
  # the last top-level one is the terminal state (its cost and turn count
  # already include the earlier invocations). Sub-agent streams are inlined
  # with a non-nil `parent_tool_use_id`; skip them so a sub-agent result can
  # never masquerade as the session result.
  defp last_result_event(objects) do
    objects
    |> Enum.filter(&(result_event?(&1) and top_level?(&1)))
    |> List.last()
  end

  defp result_event?(%{"type" => "result"}), do: true
  defp result_event?(_), do: false

  defp top_level?(%{"parent_tool_use_id" => nil}), do: true
  defp top_level?(%{"parent_tool_use_id" => _id}), do: false
  defp top_level?(_), do: true

  defp decode_line_to_list(line) do
    case decode_line(line) do
      {:ok, data} -> [data]
      _ -> []
    end
  end

  defp decode_line(line) do
    cleaned = line |> strip_terminal_codes() |> String.trim()

    if String.starts_with?(cleaned, "{") and String.ends_with?(cleaned, "}") do
      case Jason.decode(cleaned) do
        {:ok, data} -> {:ok, data}
        _ -> nil
      end
    end
  end

  defp strip_terminal_codes(line) do
    Regex.replace(~r/\e\[[0-9;?]*[a-zA-Z]/, line, "")
  end

  defp maybe_extract_plan(result, denials) when result in [nil, ""] do
    case denials do
      [%{"tool_name" => "ExitPlanMode", "tool_input" => input}] ->
        plan = input["plan"] || ""
        {plan, []}

      _ ->
        {result || "", denials}
    end
  end

  defp maybe_extract_plan(result, denials), do: {result, denials}

  defp parse_denials(nil), do: []

  defp parse_denials(denials) when is_list(denials) do
    Enum.map(denials, fn d ->
      %{
        "tool_name" => d["tool_name"] || "unknown",
        "tool_use_id" => d["tool_use_id"] || "",
        "tool_input" => d["tool_input"] || %{}
      }
    end)
  end

  defp parse_denials(_), do: []
end
