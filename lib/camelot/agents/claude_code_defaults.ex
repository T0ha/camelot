defmodule Camelot.Agents.ClaudeCodeDefaults do
  @moduledoc """
  Canonical CLI defaults for the built-in `claude_code` agent template.

  Single source of truth for the planning-stage structured-output
  contract so the seed script, the data migration, and the regression
  tests never drift. See `docs/planning-output-contract.md`.
  """

  @planning_system_prompt "You are in planning mode: investigate the " <>
                            "repository read-only, then deliver your result " <>
                            "by calling the StructuredOutput tool. Set " <>
                            ~s(decision="plan" with a complete Markdown plan ) <>
                            "when you are ready for approval, or " <>
                            ~s(decision="question" with specific questions ) <>
                            "when you need input or a decision before " <>
                            "planning can complete. Never ask questions as " <>
                            "plain assistant text; always use StructuredOutput."

  @doc "System prompt appended to the planning run."
  @spec planning_system_prompt() :: String.t()
  def planning_system_prompt, do: @planning_system_prompt

  @doc """
  JSON Schema (encoded string) passed as `--json-schema` for planning.

  The runner's Claude Code omits `ExitPlanMode` from the headless tool
  registry, so the plan/question is delivered via the injected
  `StructuredOutput` tool instead.
  """
  @spec planning_json_schema() :: String.t()
  def planning_json_schema do
    Jason.encode!(%{
      "type" => "object",
      "properties" => %{
        "decision" => %{
          "type" => "string",
          "enum" => ["plan", "question"],
          "description" =>
            ~s(Use "plan" when you have a complete implementation plan ) <>
              ~s(ready for approval. Use "question" when you need input, a ) <>
              ~s(decision, or clarification from the user before the plan ) <>
              ~s(can be finalized.)
        },
        "plan" => %{
          "type" => "string",
          "description" =>
            ~s(The full implementation plan in Markdown. Required when ) <>
              ~s(decision is "plan".)
        },
        "questions" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" =>
            ~s(One clarifying question per item. Required when decision ) <>
              ~s(is "question".)
        }
      },
      "required" => ["decision"]
    })
  end

  @doc "Per-stage permission/CLI args for the `claude_code` template."
  @spec permission_args_by_stage() :: %{optional(String.t()) => [String.t()]}
  def permission_args_by_stage do
    %{
      "planning" => [
        "--permission-mode",
        "plan",
        "--append-system-prompt",
        planning_system_prompt(),
        "--json-schema",
        planning_json_schema()
      ],
      "executing" => ["--permission-mode", "acceptEdits"]
    }
  end
end
