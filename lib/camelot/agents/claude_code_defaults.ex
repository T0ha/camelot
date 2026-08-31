defmodule Camelot.Agents.ClaudeCodeDefaults do
  @moduledoc """
  Canonical CLI defaults for the built-in `claude_code` agent template.

  Single source of truth for the planning-stage structured-output
  contract so the seed script, the data migration, and the regression
  tests never drift. See `docs/planning-output-contract.md`.

  The `*_system_prompt/0` functions below return the literal default
  body for each stage's `--append-system-prompt` text. They are the
  seed-migration source of truth and the runtime fallback used by
  `Camelot.Runtime.AgentConfig.render_permission_args/3` when the
  corresponding `PromptTemplate` row (see `*_system_prompt_slug/0`) is
  missing — the actual editable text lives in `PromptTemplate` rows at
  `/prompts`, not here.
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

  @doc "Literal default system prompt for the planning run."
  @spec planning_system_prompt() :: String.t()
  def planning_system_prompt, do: @planning_system_prompt

  @doc "Slug of the `PromptTemplate` row holding the planning system prompt."
  @spec planning_system_prompt_slug() :: String.t()
  def planning_system_prompt_slug, do: "claude_planning_system_prompt"

  @execution_system_prompt "You are running fully autonomously in a " <>
                             "headless, single-turn session: there is no " <>
                             "interactive user to answer you and no follow-up " <>
                             "turn, so you must complete the whole task before " <>
                             "your turn ends. Do NOT use background tasks or " <>
                             "run any command in the background; run every " <>
                             "command (tests, builds, git) synchronously and " <>
                             "wait for it to finish inline. Do NOT stop to " <>
                             "wait for a notification, approval, or " <>
                             "confirmation — the plan is already approved. " <>
                             "Finish the task by opening a pull request with " <>
                             "`gh pr create`, and print the resulting PR URL " <>
                             "as the last line of your final message so it is " <>
                             "captured."

  @doc "Literal default system prompt for the execution run."
  @spec execution_system_prompt() :: String.t()
  def execution_system_prompt, do: @execution_system_prompt

  @doc "Slug of the `PromptTemplate` row holding the execution system prompt."
  @spec execution_system_prompt_slug() :: String.t()
  def execution_system_prompt_slug, do: "claude_execution_system_prompt"

  @doc """
  Literal default system prompt for the pr-review run. Empty — no
  pr-stage system prompt exists yet; edit the `PromptTemplate` row at
  `/prompts` to give the pr stage one.
  """
  @spec pr_system_prompt() :: String.t()
  def pr_system_prompt, do: ""

  @doc "Slug of the `PromptTemplate` row holding the pr-review system prompt."
  @spec pr_system_prompt_slug() :: String.t()
  def pr_system_prompt_slug, do: "claude_pr_system_prompt"

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

  @doc """
  Per-stage permission/CLI args for the `claude_code` template.

  The `--append-system-prompt` values are `{{prompt:<slug>}}`
  placeholders resolved at dispatch time by
  `Camelot.Runtime.AgentConfig.render_permission_args/3` against the
  `PromptTemplate` rows named by the `*_system_prompt_slug/0`
  functions above.
  """
  @spec permission_args_by_stage() :: %{optional(String.t()) => [String.t()]}
  def permission_args_by_stage do
    %{
      "planning" => [
        "--permission-mode",
        "plan",
        "--append-system-prompt",
        "{{prompt:#{planning_system_prompt_slug()}}}",
        "--json-schema",
        planning_json_schema()
      ],
      "executing" => [
        "--permission-mode",
        "acceptEdits",
        "--append-system-prompt",
        "{{prompt:#{execution_system_prompt_slug()}}}"
      ],
      "pr" => [
        "--append-system-prompt",
        "{{prompt:#{pr_system_prompt_slug()}}}"
      ]
    }
  end
end
