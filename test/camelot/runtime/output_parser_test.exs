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

  describe "parse/2 with :kimi_jsonl" do
    test "the last assistant content is the result" do
      assert {:ok, parsed} = OutputParser.parse(:kimi_jsonl, kimi_tool_run())

      assert parsed.result_text == ~s(a.txt said "hello", so b.txt now says "world".)
      assert parsed.assistant_texts == [parsed.result_text]
      assert is_nil(parsed.structured)
      assert is_nil(parsed.usage)
      assert is_nil(parsed.cost_usd)
      assert parsed.permission_denials == []
    end

    # The bash tool's output is echoed to stderr, which the runner
    # merges into the same buffer.
    test "a JSON-only planning answer becomes structured output" do
      assert {:ok, parsed} = OutputParser.parse(:kimi_jsonl, kimi_planning_run())

      assert %{"decision" => "plan", "plan" => "# Plan: Add c.txt" <> _, "questions" => nil} =
               parsed.structured
    end

    test "a fenced JSON answer still becomes structured output" do
      answer = ~s(```json\n{"decision":"question","plan":null,"questions":["Which file?"]}\n```)

      assert {:ok, parsed} = OutputParser.parse(:kimi_jsonl, kimi_answer(answer))

      assert parsed.structured == %{
               "decision" => "question",
               "plan" => nil,
               "questions" => ["Which file?"]
             }
    end

    test "a JSON answer wrapped in prose still becomes structured output" do
      answer = ~s(Here it is:\n{"decision":"plan","plan":"Do it.","questions":null})

      assert {:ok, parsed} = OutputParser.parse(:kimi_jsonl, kimi_answer(answer))
      assert parsed.structured["plan"] == "Do it."
    end

    test "JSON without a decision is not structured output" do
      assert {:ok, parsed} = OutputParser.parse(:kimi_jsonl, kimi_answer(~s({"foo":1})))
      assert is_nil(parsed.structured)
    end

    test "interim narration alongside tool calls is collected" do
      buffer =
        Enum.join(
          [
            ~S({"role":"meta","type":"system.version","version":"2.3.0"}),
            ~S|{"role":"assistant","content":"Auto permission mode is active, so I'm directed not to use AskUserQuestion — I'll decide instead and pick `f.txt`.","tool_calls":[{"type":"function","id":"tool_rNQVprvqtbUat9UJKUQP5oYC","function":{"name":"Write","arguments":"{\"path\":\"f.txt\",\"content\":\"\"}"}}]}|,
            ~S({"role":"tool","tool_call_id":"tool_rNQVprvqtbUat9UJKUQP5oYC","content":"Wrote 0 bytes to f.txt"}),
            ~S({"role":"assistant","content":"Created f.txt."})
          ],
          "\n"
        )

      assert {:ok, parsed} = OutputParser.parse(:kimi_jsonl, buffer)
      assert parsed.result_text == "Created f.txt."
      assert length(parsed.assistant_texts) == 2
    end

    test "a failed prompt is an error carrying the CLI's message" do
      buffer = ~S"""
      {"role":"meta","type":"system.version","version":"2.3.0"}
      error: failed to run prompt: provider.auth_error: 401 The API Key appears to be invalid or may have expired. Please verify your credentials and try again.
      See log: /home/runner/.kimi-code/logs/kimi-code.log
      """

      assert {:error, message} = OutputParser.parse(:kimi_jsonl, buffer)

      assert message ==
               "kimi error: provider.auth_error: 401 The API Key appears to " <>
                 "be invalid or may have expired. Please verify your " <>
                 "credentials and try again."
    end

    test "an unknown model alias is an error" do
      buffer = ~S"""
      {"role":"meta","type":"system.version","version":"2.3.0"}
      error: failed to run prompt: Model "kimi-code/does-not-exist" is not configured in config.toml.
      See log: /home/runner/.kimi-code/logs/kimi-code.log
      """

      assert {:error, ~S(kimi error: Model "kimi-code/does-not-exist" is not configured in config.toml.)} =
               OutputParser.parse(:kimi_jsonl, buffer)
    end

    test "a usage error with no JSON at all is an error" do
      assert {:error, "kimi error: Cannot combine --prompt with --plan."} =
               OutputParser.parse(:kimi_jsonl, "error: Cannot combine --prompt with --plan.\n")
    end

    test "nothing recognisable is reported as such" do
      assert {:error, "no JSON object found in output"} =
               OutputParser.parse(:kimi_jsonl, "kimi: command not found\n")

      assert {:error, "no JSON object found in output"} = OutputParser.parse(:kimi_jsonl, "")
    end

    # Appendix A1 of the integration plan (kimi-code 2.3.0).
    defp kimi_tool_run do
      ~S"""
      {"role":"meta","type":"system.version","version":"2.3.0"}
      {"role":"assistant","tool_calls":[{"type":"function","id":"tool_HqJ8NkVggJB6qskKY8pLF7rt","function":{"name":"Read","arguments":"{\"path\":\"a.txt\"}"}}]}
      {"role":"tool","tool_call_id":"tool_HqJ8NkVggJB6qskKY8pLF7rt","content":"1\thello"}
      {"role":"assistant","tool_calls":[{"type":"function","id":"tool_jygumKbEyF0nQWbncBkl0mZz","function":{"name":"Write","arguments":"{\"path\":\"b.txt\",\"content\":\"world\"}"}}]}
      {"role":"tool","tool_call_id":"tool_jygumKbEyF0nQWbncBkl0mZz","content":"Wrote 5 bytes to b.txt"}
      {"role":"assistant","content":"a.txt said \"hello\", so b.txt now says \"world\"."}
      {"role":"meta","type":"session.resume_hint","session_id":"session_ff7881af-366a-4f26-84a5-1712d1410c6a","command":"kimi -r session_ff7881af-366a-4f26-84a5-1712d1410c6a","content":"To resume this session: kimi -r session_ff7881af-366a-4f26-84a5-1712d1410c6a"}
      """
    end

    # Appendix A2, with the echoed `ls` stderr interleaved.
    defp kimi_planning_run do
      ~S"""
      {"role":"meta","type":"system.version","version":"2.3.0"}
      {"role":"assistant","tool_calls":[{"type":"function","id":"tool_D1H6T4WIG9Z81icv2qaTNoXh","function":{"name":"Bash","arguments":"{\"command\":\"ls\"}"}}]}
      a.txt
      b.txt
      {"role":"tool","tool_call_id":"tool_D1H6T4WIG9Z81icv2qaTNoXh","content":"a.txt\nb.txt\n"}
      {"role":"assistant","content":"{\"decision\":\"plan\",\"plan\":\"# Plan: Add c.txt\\n\\n## Current state\\nThe working directory contains `a.txt` and `b.txt` (confirmed via `ls`). No `c.txt` exists yet.\\n\\n## Steps\\n1. Inspect `a.txt` and `b.txt` to match their content style and conventions.\\n2. Create `c.txt` in the working directory root with content consistent with the existing files.\\n3. Run `ls` to verify `c.txt` appears alongside `a.txt` and `b.txt`.\\n\\n## Verification\\n- `ls` output lists `a.txt`, `b.txt`, and `c.txt`.\\n- `c.txt` content follows the same format as the existing files.\",\"questions\":null}"}
      {"role":"meta","type":"session.resume_hint","session_id":"session_d3d03cae-1247-4a33-b777-f8e1e7105be4","command":"kimi -r session_d3d03cae-1247-4a33-b777-f8e1e7105be4","content":"To resume this session: kimi -r session_d3d03cae-1247-4a33-b777-f8e1e7105be4"}
      """
    end

    defp kimi_answer(answer) do
      Enum.join(
        [
          ~S({"role":"meta","type":"system.version","version":"2.3.0"}),
          Jason.encode!(%{"role" => "assistant", "content" => answer})
        ],
        "\n"
      )
    end
  end
end
