defmodule Camelot.Runtime.OutputParser do
  @moduledoc """
  Parses CLI output based on agent type.

  Claude Code JSON output contains a `result` field with the
  response text, plus optional `is_error`, `cost_usd`, and
  `duration_ms` metadata. Codex returns raw text.
  """

  @type parsed :: %{
          result_text: String.t(),
          cost_usd: float() | nil,
          duration_ms: integer() | nil
        }

  @spec parse(:claude_code | :codex, String.t()) ::
          {:ok, parsed()} | {:error, String.t()}
  def parse(:codex, buffer) do
    {:ok, %{result_text: buffer, cost_usd: nil, duration_ms: nil}}
  end

  def parse(:claude_code, "") do
    {:error, "empty output"}
  end

  def parse(:claude_code, buffer) do
    case Jason.decode(buffer) do
      {:ok, %{"is_error" => true, "result" => message}} ->
        {:error, message}

      {:ok, %{"result" => result} = data} ->
        {:ok,
         %{
           result_text: result,
           cost_usd: data["cost_usd"],
           duration_ms: data["duration_ms"]
         }}

      {:ok, _} ->
        {:error, "unexpected JSON structure"}

      {:error, _} ->
        {:error, "malformed JSON output"}
    end
  end
end
