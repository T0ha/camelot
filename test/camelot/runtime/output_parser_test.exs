defmodule Camelot.Runtime.OutputParserTest do
  use ExUnit.Case, async: true

  alias Camelot.Runtime.OutputParser

  describe "parse/2 with :claude_code_json" do
    test "parses successful JSON response" do
      buffer =
        Jason.encode!(%{
          "result" => "Here is the plan...",
          "cost_usd" => 0.05,
          "duration_ms" => 1234
        })

      assert {:ok, parsed} = OutputParser.parse(:claude_code_json, buffer)
      assert parsed.result_text == "Here is the plan..."
      assert parsed.cost_usd == 0.05
      assert parsed.duration_ms == 1234
    end

    test "parses JSON response without optional fields" do
      buffer = Jason.encode!(%{"result" => "Done."})

      assert {:ok, parsed} = OutputParser.parse(:claude_code_json, buffer)
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

      assert {:error, "claude error: Something went wrong"} =
               OutputParser.parse(:claude_code_json, buffer)
    end

    test "returns error for empty buffer" do
      assert {:error, "empty output"} =
               OutputParser.parse(:claude_code_json, "")
    end

    test "returns error when no JSON object is in the output" do
      assert {:error, "no JSON object found in output"} =
               OutputParser.parse(:claude_code_json, "not json at all")
    end

    test "extracts JSON from a noisy buffer (entrypoint logs + escape codes)" do
      buffer = """
      [entrypoint] no REPO_URL set; skipping clone
      [entrypoint] exec: claude --output-format json -p hello
      {"result": "Done.", "is_error": false}
      \e[?1006l\e[?1003l
      """

      assert {:ok, %{result_text: "Done.", permission_denials: []}} =
               OutputParser.parse(:claude_code_json, buffer)
    end

    test "returns error for unexpected JSON structure" do
      buffer = Jason.encode!(%{"foo" => "bar"})

      assert {:error, "unexpected JSON structure"} =
               OutputParser.parse(:claude_code_json, buffer)
    end
  end

  describe "parse/2 with :claude_code_json — stream-json (NDJSON)" do
    test "picks the type:result event out of a multi-line stream" do
      buffer =
        Enum.map_join(
          [
            %{"type" => "system", "subtype" => "init", "session_id" => "abc"},
            %{"type" => "assistant", "message" => %{"content" => [%{"type" => "text", "text" => "working"}]}},
            %{
              "type" => "result",
              "subtype" => "success",
              "is_error" => false,
              "result" => "All done.",
              "total_cost_usd" => 0.12,
              "duration_ms" => 4567,
              "permission_denials" => []
            }
          ],
          "\n",
          &Jason.encode!/1
        )

      assert {:ok, parsed} = OutputParser.parse(:claude_code_json, buffer)
      assert parsed.result_text == "All done."
      assert parsed.cost_usd == 0.12
      assert parsed.duration_ms == 4567
      assert parsed.permission_denials == []
    end

    test "prefers type:result even when a later line also decodes" do
      buffer =
        Enum.map_join(
          [
            %{"type" => "result", "result" => "the answer", "is_error" => false},
            %{"type" => "trailing", "note" => "should be ignored"}
          ],
          "\n",
          &Jason.encode!/1
        )

      assert {:ok, %{result_text: "the answer"}} =
               OutputParser.parse(:claude_code_json, buffer)
    end

    test "surfaces is_error from a stream-json result event" do
      buffer =
        Enum.map_join(
          [%{"type" => "system", "subtype" => "init"}, %{"type" => "result", "is_error" => true, "result" => "boom"}],
          "\n",
          &Jason.encode!/1
        )

      assert {:error, "claude error: boom"} =
               OutputParser.parse(:claude_code_json, buffer)
    end

    test "picks the last result event of a resumed (multi-invocation) session" do
      buffer =
        Enum.map_join(
          [
            %{"type" => "system", "subtype" => "init", "session_id" => "s1"},
            %{
              "type" => "result",
              "subtype" => "success",
              "is_error" => false,
              "result" => "I'll wait for the exploration agent's findings.",
              "total_cost_usd" => 0.18,
              "num_turns" => 4,
              "permission_denials" => []
            },
            %{"type" => "system", "subtype" => "init", "session_id" => "s1"},
            %{"type" => "assistant", "message" => %{"content" => [%{"type" => "text", "text" => "writing plan"}]}},
            %{
              "type" => "result",
              "subtype" => "success",
              "is_error" => false,
              "result" => "I've completed the plan.",
              "total_cost_usd" => 0.74,
              "num_turns" => 8,
              "permission_denials" => []
            }
          ],
          "\n",
          &Jason.encode!/1
        )

      assert {:ok, parsed} = OutputParser.parse(:claude_code_json, buffer)
      assert parsed.result_text == "I've completed the plan."
      # The last event is a cumulative snapshot: take its cost, don't sum.
      assert parsed.cost_usd == 0.74
    end

    test "ignores sub-agent result events (non-nil parent_tool_use_id)" do
      buffer =
        Enum.map_join(
          [
            %{"type" => "system", "subtype" => "init"},
            %{
              "type" => "result",
              "is_error" => false,
              "result" => "session result",
              "parent_tool_use_id" => nil
            },
            %{
              "type" => "result",
              "is_error" => false,
              "result" => "sub-agent result",
              "parent_tool_use_id" => "toolu_123"
            }
          ],
          "\n",
          &Jason.encode!/1
        )

      assert {:ok, %{result_text: "session result"}} =
               OutputParser.parse(:claude_code_json, buffer)
    end
  end

  describe "parse/2 with :raw_text" do
    test "returns raw text as-is" do
      buffer = "some raw output\nwith newlines"

      assert {:ok, parsed} = OutputParser.parse(:raw_text, buffer)
      assert parsed.result_text == buffer
      assert is_nil(parsed.cost_usd)
      assert is_nil(parsed.duration_ms)
    end
  end
end
