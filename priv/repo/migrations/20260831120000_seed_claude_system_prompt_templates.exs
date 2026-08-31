defmodule Camelot.Repo.Migrations.SeedClaudeSystemPromptTemplates do
  @moduledoc """
  Seeds the three global `PromptTemplate` rows backing the Claude Code
  `--append-system-prompt` text for the planning, executing, and pr
  stages, so that text is editable at `/prompts` instead of being a
  hardcoded Elixir string in `Camelot.Agents.ClaudeCodeDefaults`.

  Bodies are pasted verbatim from the current
  `ClaudeCodeDefaults.planning_system_prompt/0` /
  `execution_system_prompt/0` literals as a frozen snapshot — not
  called dynamically, so this migration's effect never changes if
  those functions are edited later. `claude_pr_system_prompt` has no
  prior text (the pr stage never had a system prompt) so it seeds
  empty, per follow-up feedback requesting the slug exist now for
  consistency.

  Inserts are guarded by `WHERE NOT EXISTS`, following
  `20260604063740_seed_default_prompt_templates.exs`: the unique index
  on `(slug, project_id)` does not catch duplicates when
  `project_id IS NULL` (PostgreSQL treats NULLs as distinct).
  """

  use Ecto.Migration

  @planning_body "You are in planning mode: investigate the " <>
                   "repository read-only, then deliver your result " <>
                   "by calling the StructuredOutput tool. Set " <>
                   ~s(decision="plan" with a complete Markdown plan ) <>
                   "when you are ready for approval, or " <>
                   ~s(decision="question" with specific questions ) <>
                   "when you need input or a decision before " <>
                   "planning can complete. Never ask questions as " <>
                   "plain assistant text; always use StructuredOutput."

  @execution_body "You are running fully autonomously in a " <>
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

  @pr_body ""

  def up do
    seed(
      "claude_planning_system_prompt",
      "Claude Planning System Prompt",
      @planning_body,
      "Appended via --append-system-prompt during the planning stage. " <>
        "Plain text — no {{variable}} interpolation."
    )

    seed(
      "claude_execution_system_prompt",
      "Claude Execution System Prompt",
      @execution_body,
      "Appended via --append-system-prompt during the executing stage. " <>
        "Plain text — no {{variable}} interpolation."
    )

    seed(
      "claude_pr_system_prompt",
      "Claude PR Review System Prompt",
      @pr_body,
      "Appended via --append-system-prompt during the pr-review stage. " <>
        "Currently unset — edit this row to give the pr stage a system " <>
        "prompt. Plain text — no {{variable}} interpolation."
    )
  end

  def down do
    execute("""
    DELETE FROM prompt_templates
     WHERE project_id IS NULL
       AND user_id IS NULL
       AND slug IN (
         'claude_planning_system_prompt',
         'claude_execution_system_prompt',
         'claude_pr_system_prompt'
       )
    """)
  end

  defp seed(slug, name, body, description) do
    execute("""
    INSERT INTO prompt_templates (slug, name, body, description)
    SELECT #{quote_str(slug)},
           #{quote_str(name)},
           #{quote_str(body)},
           #{quote_str(description)}
     WHERE NOT EXISTS (
       SELECT 1 FROM prompt_templates
        WHERE slug = #{quote_str(slug)}
          AND project_id IS NULL
          AND user_id IS NULL
     )
    """)
  end

  defp quote_str(s) do
    "'" <> String.replace(s, "'", "''") <> "'"
  end
end
