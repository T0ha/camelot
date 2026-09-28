defmodule Camelot.Runtime.OutputParserTest do
  use ExUnit.Case, async: true

  alias Camelot.Runtime.OutputParser

  describe "parse/2 with :claude_code_json" do
    test "parses successful JSON response" do
      buffer =
        Jason.encode!(%{
          "result" => "Here is the plan...",
          "cost_usd" => 0.05,
          "duration_ms" => 1234,
          "duration_api_ms" => 987,
          "num_turns" => 3,
          "usage" => %{"input_tokens" => 100, "output_tokens" => 50}
        })

      assert {:ok, parsed} = OutputParser.parse(:claude_code_json, buffer)
      assert parsed.result_text == "Here is the plan..."
      assert parsed.cost_usd == 0.05
      assert parsed.duration_ms == 1234
      assert parsed.duration_api_ms == 987
      assert parsed.num_turns == 3
      assert parsed.usage == %{"input_tokens" => 100, "output_tokens" => 50}
    end

    test "parses JSON response without optional fields" do
      buffer = Jason.encode!(%{"result" => "Done."})

      assert {:ok, parsed} = OutputParser.parse(:claude_code_json, buffer)
      assert parsed.result_text == "Done."
      assert is_nil(parsed.cost_usd)
      assert is_nil(parsed.duration_ms)
      assert is_nil(parsed.duration_api_ms)
      assert is_nil(parsed.num_turns)
      assert is_nil(parsed.usage)
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

    test "surfaces structured_output from a --json-schema result" do
      buffer =
        Jason.encode!(%{
          "result" => ~s({"decision":"plan","plan":"Do the thing"}),
          "structured_output" => %{
            "decision" => "plan",
            "plan" => "Do the thing"
          },
          "is_error" => false
        })

      assert {:ok, parsed} = OutputParser.parse(:claude_code_json, buffer)
      assert parsed.structured == %{"decision" => "plan", "plan" => "Do the thing"}
    end

    test "structured is nil when absent" do
      buffer = Jason.encode!(%{"result" => "plain text"})

      assert {:ok, %{structured: nil}} =
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

    test "extracts num_turns, duration_api_ms, and usage from a result event" do
      buffer =
        Jason.encode!(%{
          "result" => "All done.",
          "num_turns" => 6,
          "duration_api_ms" => 2345,
          "usage" => %{
            "input_tokens" => 10,
            "output_tokens" => 20,
            "cache_creation_input_tokens" => 5,
            "cache_read_input_tokens" => 15
          }
        })

      assert {:ok, parsed} = OutputParser.parse(:claude_code_json, buffer)
      assert parsed.num_turns == 6
      assert parsed.duration_api_ms == 2345

      assert parsed.usage == %{
               "input_tokens" => 10,
               "output_tokens" => 20,
               "cache_creation_input_tokens" => 5,
               "cache_read_input_tokens" => 15
             }
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

    test "falls back to the last non-blank result when the final turn is empty" do
      # Regression: a resumed session's final invocation can be a wake/yield
      # turn that emits an empty result; the real answer from an earlier
      # invocation (still in the log) must not be discarded.
      buffer =
        Enum.map_join(
          [
            %{
              "type" => "result",
              "subtype" => "success",
              "result" => "Here is the real answer.",
              "permission_denials" => []
            },
            %{
              "type" => "result",
              "subtype" => "success",
              "result" => "",
              "permission_denials" => []
            }
          ],
          "\n",
          &Jason.encode!/1
        )

      assert {:ok, parsed} = OutputParser.parse(:claude_code_json, buffer)
      assert parsed.result_text == "Here is the real answer."
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

    test "collects all top-level assistant text blocks" do
      buffer =
        Enum.map_join(
          [
            %{"type" => "system", "subtype" => "init"},
            %{
              "type" => "assistant",
              "parent_tool_use_id" => nil,
              "message" => %{"content" => [%{"type" => "text", "text" => "Here is my question with options."}]}
            },
            %{
              "type" => "assistant",
              "parent_tool_use_id" => "toolu_sub",
              "message" => %{"content" => [%{"type" => "text", "text" => "sub-agent chatter"}]}
            },
            %{
              "type" => "assistant",
              "parent_tool_use_id" => nil,
              "message" => %{"content" => [%{"type" => "text", "text" => "I'll wait for your decision."}]}
            },
            %{"type" => "result", "is_error" => false, "result" => "I'll wait for your decision."}
          ],
          "\n",
          &Jason.encode!/1
        )

      assert {:ok, parsed} = OutputParser.parse(:claude_code_json, buffer)
      # Sub-agent text (non-nil parent_tool_use_id) is excluded; order preserved.
      assert parsed.assistant_texts == [
               "Here is my question with options.",
               "I'll wait for your decision."
             ]
    end

    test "surfaces structured_output from a stream-json result event" do
      buffer =
        Enum.map_join(
          [
            %{"type" => "system", "subtype" => "init", "tools" => ["StructuredOutput"]},
            %{
              "type" => "assistant",
              "parent_tool_use_id" => nil,
              "message" => %{
                "content" => [
                  %{"type" => "tool_use", "name" => "StructuredOutput", "input" => %{"decision" => "question"}}
                ]
              }
            },
            %{
              "type" => "result",
              "subtype" => "success",
              "is_error" => false,
              "result" => ~s({"decision":"question","questions":["Which DB?"]}),
              "structured_output" => %{"decision" => "question", "questions" => ["Which DB?"]}
            }
          ],
          "\n",
          &Jason.encode!/1
        )

      assert {:ok, parsed} = OutputParser.parse(:claude_code_json, buffer)
      assert parsed.structured == %{"decision" => "question", "questions" => ["Which DB?"]}
    end
  end

  describe "parse/2 with :raw_text" do
    test "returns raw text as-is" do
      buffer = "some raw output\nwith newlines"

      assert {:ok, parsed} = OutputParser.parse(:raw_text, buffer)
      assert parsed.result_text == buffer
      assert is_nil(parsed.cost_usd)
      assert is_nil(parsed.duration_ms)
      assert is_nil(parsed.duration_api_ms)
      assert is_nil(parsed.num_turns)
      assert is_nil(parsed.usage)
      assert is_nil(parsed.structured)
      assert parsed.assistant_texts == []
    end
  end

  describe "parse/2 with :codex_jsonl" do
    test "keeps the agent's answer and drops the run's working noise" do
      assert {:ok, parsed} = OutputParser.parse(:codex_jsonl, codex_stream())

      assert parsed.result_text == "## Plan\n\n1. Do the thing."

      # The reasoning and command_execution items — the 122 KB of `rg`
      # output that used to become the plan — are gone.
      refute parsed.result_text =~ "lib/bodhi/llm.ex"
      refute parsed.result_text =~ "rg -n"
    end

    test "drops the progress narration Codex emits ahead of the answer" do
      assert {:ok, parsed} = OutputParser.parse(:codex_jsonl, codex_stream())

      # "Investigating the config path." is its own agent_message item,
      # emitted before the plan. Joining it in would prefix every plan
      # with throat-clearing and push a clarifying question past the
      # 500-character ceiling that marks one as a question.
      assert parsed.assistant_texts == ["## Plan\n\n1. Do the thing."]
      refute parsed.result_text =~ "Investigating"
    end

    test "reads token usage and turn count off turn.completed" do
      assert {:ok, parsed} = OutputParser.parse(:codex_jsonl, codex_stream())

      assert parsed.usage == %{
               "input_tokens" => 25_809,
               "cached_input_tokens" => 16_896,
               "output_tokens" => 137,
               "reasoning_output_tokens" => 17
             }

      assert parsed.num_turns == 1
      assert is_nil(parsed.cost_usd)
      assert is_nil(parsed.structured)
      assert parsed.permission_denials == []
    end

    test "tolerates the CLI's non-JSON stderr notes in the same buffer" do
      buffer =
        "Reading additional input from stdin...\n" <>
          codex_stream() <> "\nstream disconnected before completion\n"

      assert {:ok, parsed} = OutputParser.parse(:codex_jsonl, buffer)
      assert parsed.result_text == "## Plan\n\n1. Do the thing."
    end

    test "surfaces turn.failed as an error even when the run exited cleanly" do
      buffer =
        Enum.join(
          [
            ~s({"type":"thread.started","thread_id":"t1"}),
            ~s({"type":"turn.started"}),
            ~s({"type":"turn.failed","error":{"message":"usage limit reached"}})
          ],
          "\n"
        )

      assert {:error, message} = OutputParser.parse(:codex_jsonl, buffer)
      assert message == "codex error: usage limit reached"
    end

    test "reports a turn.failed with no message rather than crashing" do
      buffer = ~s({"type":"turn.failed"})

      assert {:error, message} = OutputParser.parse(:codex_jsonl, buffer)
      assert message =~ "codex error:"
    end

    test "errors on a buffer with no decodable event" do
      assert {:error, "no JSON object found in output"} =
               OutputParser.parse(:codex_jsonl, "codex: command not found\n")

      assert {:error, "no JSON object found in output"} =
               OutputParser.parse(:codex_jsonl, "")
    end

    test "a run that produced no agent message parses as empty, not as noise" do
      buffer =
        Enum.join(
          [
            ~s({"type":"thread.started","thread_id":"t1"}),
            ~s({"type":"item.completed","item":{"id":"i0","type":"reasoning","text":"hmm"}}),
            ~s({"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":2}})
          ],
          "\n"
        )

      assert {:ok, parsed} = OutputParser.parse(:codex_jsonl, buffer)
      assert parsed.result_text == ""
      assert parsed.assistant_texts == []
    end

    test "a short question is left short enough for TaskRunner to recognise" do
      buffer =
        Enum.join(
          [
            ~s({"type":"item.completed","item":{"id":"i0","type":"agent_message","text":"Looking into the config path and the admin screens now."}}),
            ~s({"type":"item.completed","item":{"id":"i1","type":"agent_message","text":"Is the model global or per-chat?"}}),
            ~s({"type":"turn.completed","usage":{}})
          ],
          "\n"
        )

      assert {:ok, parsed} = OutputParser.parse(:codex_jsonl, buffer)
      assert parsed.result_text == "Is the model global or per-chat?"
      assert String.length(parsed.result_text) < 500
    end

    test "surfaces a schema-validated final message as structured output" do
      # Verbatim from a real `--output-schema` run (codex-cli 0.155.0):
      # the final agent_message is the validated object itself.
      buffer =
        ~s({"type":"item.completed","item":{"id":"item_0","type":"agent_message",) <>
          ~s("text":"{\\"decision\\":\\"plan\\",\\"plan\\":\\"Add the flag.\\",\\"questions\\":null}"}})

      assert {:ok, parsed} = OutputParser.parse(:codex_jsonl, buffer)

      assert parsed.structured == %{
               "decision" => "plan",
               "plan" => "Add the flag.",
               "questions" => nil
             }
    end

    test "leaves structured nil when the run had no schema" do
      assert {:ok, parsed} = OutputParser.parse(:codex_jsonl, codex_stream())
      assert is_nil(parsed.structured)
    end

    # Verbatim event shapes from `codex exec --json` (codex-cli 0.155.0).
    defp codex_stream do
      Enum.join(
        [
          ~s({"type":"thread.started","thread_id":"01a0c7ce-be4a-7ff1-92e9-37dbb65eb2f3"}),
          ~s({"type":"turn.started"}),
          ~s({"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"Investigating the config path."}}),
          ~s({"type":"item.completed","item":{"id":"item_1","type":"reasoning","text":"The user wants a plan."}}),
          ~s({"type":"item.started","item":{"id":"item_2","type":"command_execution","command":"/bin/zsh -lc \\"rg -n model lib\\"","aggregated_output":"","exit_code":null,"status":"in_progress"}}),
          ~s({"type":"item.completed","item":{"id":"item_2","type":"command_execution","command":"/bin/zsh -lc \\"rg -n model lib\\"","aggregated_output":"lib/bodhi/llm.ex:1:defmodule Bodhi.LLM do","exit_code":0,"status":"completed"}}),
          ~s({"type":"item.completed","item":{"id":"item_3","type":"agent_message","text":"## Plan\\n\\n1. Do the thing."}}),
          ~s({"type":"turn.completed","usage":{"input_tokens":25809,"cached_input_tokens":16896,"output_tokens":137,"reasoning_output_tokens":17}})
        ],
        "\n"
      )
    end
  end
end
