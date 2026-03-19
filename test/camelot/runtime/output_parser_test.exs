defmodule Camelot.Runtime.OutputParserTest do
  use ExUnit.Case, async: true

  alias Camelot.Runtime.OutputParser

  describe "parse/2 with :claude_code" do
    test "parses successful JSON response" do
      buffer =
        Jason.encode!(%{
          "result" => "Here is the plan...",
          "cost_usd" => 0.05,
          "duration_ms" => 1234
        })

      assert {:ok, parsed} = OutputParser.parse(:claude_code, buffer)
      assert parsed.result_text == "Here is the plan..."
      assert parsed.cost_usd == 0.05
      assert parsed.duration_ms == 1234
    end

    test "parses JSON response without optional fields" do
      buffer = Jason.encode!(%{"result" => "Done."})

      assert {:ok, parsed} = OutputParser.parse(:claude_code, buffer)
      assert parsed.result_text == "Done."
      assert is_nil(parsed.cost_usd)
      assert is_nil(parsed.duration_ms)
    end

    test "returns error for is_error response" do
      buffer =
        Jason.encode!(%{
          "result" => "Something went wrong",
          "is_error" => true
        })

      assert {:error, "Something went wrong"} =
               OutputParser.parse(:claude_code, buffer)
    end

    test "returns error for empty buffer" do
      assert {:error, "empty output"} =
               OutputParser.parse(:claude_code, "")
    end

    test "returns error for malformed JSON" do
      assert {:error, "malformed JSON output"} =
               OutputParser.parse(:claude_code, "not json at all")
    end

    test "returns error for unexpected JSON structure" do
      buffer = Jason.encode!(%{"foo" => "bar"})

      assert {:error, "unexpected JSON structure"} =
               OutputParser.parse(:claude_code, buffer)
    end
  end

  describe "parse/2 with :codex" do
    test "returns raw text as-is" do
      buffer = "some raw output\nwith newlines"

      assert {:ok, parsed} = OutputParser.parse(:codex, buffer)
      assert parsed.result_text == buffer
      assert is_nil(parsed.cost_usd)
      assert is_nil(parsed.duration_ms)
    end
  end
end
