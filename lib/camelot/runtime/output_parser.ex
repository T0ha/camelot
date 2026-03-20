defmodule Camelot.Runtime.OutputParser do
  @moduledoc """
  Parses CLI output based on agent type.

  Claude Code JSON output contains a `result` field with the
  response text, plus optional `is_error`, `cost_usd`, and
  `duration_ms` metadata. Codex returns raw text.
  """

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

  @spec parse(:claude_code | :codex, String.t()) ::
          {:ok, parsed()} | {:error, String.t()}
  def parse(:codex, buffer) do
    {:ok,
     %{
       result_text: buffer,
       cost_usd: nil,
       duration_ms: nil,
       permission_denials: []
     }}
  end

  def parse(:claude_code, "") do
    {:error, "empty output"}
  end

  def parse(:claude_code, buffer) do
    case Jason.decode(buffer) do
      {:ok, %{"is_error" => true, "result" => message}} ->
        {:error, message}

      {:ok, %{"result" => result} = data} ->
        denials = parse_denials(data["permission_denials"])

        {result_text, denials} =
          maybe_extract_plan(result, denials)

        {:ok,
         %{
           result_text: result_text,
           cost_usd: data["cost_usd"],
           duration_ms: data["duration_ms"],
           permission_denials: denials
         }}

      {:ok, _} ->
        {:error, "unexpected JSON structure"}

      {:error, _} ->
        {:error, "malformed JSON output"}
    end
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
