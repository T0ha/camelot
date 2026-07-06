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
          permission_denials: [permission_denial()]
        }

  @spec parse(parser(), String.t()) ::
          {:ok, parsed()} | {:error, String.t()}
  def parse(:raw_text, buffer) do
    {:ok,
     %{
       result_text: buffer,
       cost_usd: nil,
       duration_ms: nil,
       permission_denials: []
     }}
  end

  def parse(:claude_code_json, "") do
    {:error, "empty output"}
  end

  def parse(:claude_code_json, buffer) do
    case extract_json(buffer) do
      {:ok, %{"is_error" => true, "result" => message}} when is_binary(message) ->
        {:error, "claude error: " <> message}

      {:ok, %{"result" => result} = data} ->
        denials = parse_denials(data["permission_denials"])
        {result_text, denials} = maybe_extract_plan(result, denials)

        {:ok,
         %{
           result_text: result_text,
           cost_usd: data["cost_usd"] || data["total_cost_usd"],
           duration_ms: data["duration_ms"],
           permission_denials: denials
         }}

      {:ok, _} ->
        {:error, "unexpected JSON structure"}

      :error ->
        {:error, "no JSON object found in output"}
    end
  end

  # Tries the whole buffer first (fast path for a single-object
  # `--output-format json` result), then falls back to scanning the
  # per-line objects. Container runners emit entrypoint log lines
  # before the CLI output and terminal escape codes after, so a
  # whole-buffer decode often fails even though valid JSON lines are
  # in there.
  defp extract_json(buffer) do
    case Jason.decode(String.trim(buffer)) do
      {:ok, data} -> {:ok, data}
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

    pick_object(Enum.find(objects, &result_event?/1), objects)
  end

  defp pick_object(nil, []), do: :error
  defp pick_object(nil, objects), do: {:ok, List.last(objects)}
  defp pick_object(result, _objects), do: {:ok, result}

  defp result_event?(%{"type" => "result"}), do: true
  defp result_event?(_), do: false

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
