defmodule Camelot.Repo.Migrations.FixCodexForModernCli do
  @moduledoc """
  Repairs the `codex` agent row, which was seeded by
  `20260527063144_add_agent_templates.exs` against a Codex CLI that no
  longer exists.

  The row carried `base_args = ['--quiet']`. The modern CLI
  (`codex exec`, 0.4x+) has no such flag and puts non-interactive runs
  behind the `exec` subcommand, so every dispatch died with
  `error: unexpected argument '--quiet' found` and exit 2 before any
  model call — the run then retried `max_retries` times and errored the
  task. Alongside that it had no sandbox args (the modern CLI needs an
  explicit posture, there being no TTY to approve at), no
  `runner_image` (nil resolves to `alpine:latest`, which has no `codex`
  binary), no `required_credential_kinds` (so no `OPENAI_API_KEY` was
  ever mounted) and no per-stage system prompt.

  Values are frozen literals rather than calls into
  `Camelot.Agents.CodexDefaults`, following
  `20260831120000_seed_claude_system_prompt_templates.exs`: this
  migration's effect must not change if those defaults are edited
  later.

  Both halves are guarded so a hand-customised install survives:

    * the agent row is only rewritten while `base_args` still equals
      exactly `['--quiet']` — the exact-value precedent from
      `20260831120100_claude_append_system_prompt_placeholders.exs`,
      since the row is editable at `/agents`;

    * the `PromptTemplate` rows insert under `WHERE NOT EXISTS` and
      `down` only deletes one whose body still matches what `up`
      wrote, so an edit made at `/prompts` is never destroyed.
  """

  use Ecto.Migration

  @old_base_args ["--quiet"]
  @new_base_args ["exec", "--skip-git-repo-check", "--color", "never"]

  @permission_args %{
    "planning" => ["--sandbox", "read-only"],
    "executing" => ["--dangerously-bypass-approvals-and-sandbox"],
    "pr" => ["--dangerously-bypass-approvals-and-sandbox"]
  }

  @system_prompts %{
    "planning" => "{{prompt:codex_planning_system_prompt}}",
    "executing" => "{{prompt:codex_execution_system_prompt}}",
    "pr" => "{{prompt:codex_pr_system_prompt}}"
  }

  @question_phrases [
    "could you",
    "can you",
    "please provide",
    "please clarify",
    "please specify",
    "what would",
    "which approach",
    "do you want",
    "would you like",
    "waiting for",
    "need more information",
    "let me know"
  ]

  @runner_image "ghcr.io/t0ha/camelot-runner-codex:latest"

  @planning_body "You are in planning mode: investigate the " <>
                   "repository read-only and do not modify, " <>
                   "create, or delete any file. End your final " <>
                   "message with the complete implementation plan " <>
                   "in Markdown — that message is captured verbatim " <>
                   "as the plan for approval. If you instead need " <>
                   "input or a decision before the plan can be " <>
                   "finished, reply with nothing but your questions, " <>
                   "one per line, in under 400 characters."

  @execution_body "You are running fully autonomously in a " <>
                    "headless, single-turn session: there is no " <>
                    "interactive user to answer you and no follow-up " <>
                    "turn, so you must complete the whole task before " <>
                    "your turn ends. Do NOT run any command in the " <>
                    "background; run every command (tests, builds, " <>
                    "git) synchronously and wait for it to finish " <>
                    "inline. Do NOT stop to wait for a notification, " <>
                    "approval, or confirmation — the plan is already " <>
                    "approved. Finish the task by opening a pull " <>
                    "request with `gh pr create`, and print the " <>
                    "resulting PR URL as the last line of your final " <>
                    "message so it is captured."

  @pr_body "You are addressing review feedback and CI failures on " <>
             "an existing pull request, autonomously and in a " <>
             "single turn. Push your fixes to the pull request's " <>
             "own branch — do not open a second pull request — and " <>
             "print the pull request URL as the last line of your " <>
             "final message."

  def up do
    seed_template(
      "codex_planning_system_prompt",
      "Codex Planning System Prompt",
      @planning_body,
      "Prepended to the prompt during the planning stage — Codex has " <>
        "no --append-system-prompt flag. Plain text, no {{variable}} " <>
        "interpolation."
    )

    seed_template(
      "codex_execution_system_prompt",
      "Codex Execution System Prompt",
      @execution_body,
      "Prepended to the prompt during the executing stage. Plain " <>
        "text, no {{variable}} interpolation."
    )

    seed_template(
      "codex_pr_system_prompt",
      "Codex PR Review System Prompt",
      @pr_body,
      "Prepended to the prompt during the pr-review stage. Plain " <>
        "text, no {{variable}} interpolation."
    )

    rewrite_codex_row(
      @old_base_args,
      @new_base_args,
      @permission_args,
      @system_prompts,
      @question_phrases,
      @runner_image,
      ["codex_api_key"]
    )
  end

  def down do
    rewrite_codex_row(
      @new_base_args,
      @old_base_args,
      %{},
      %{},
      [],
      nil,
      []
    )

    unseed_template("codex_planning_system_prompt", @planning_body)
    unseed_template("codex_execution_system_prompt", @execution_body)
    unseed_template("codex_pr_system_prompt", @pr_body)
  end

  defp rewrite_codex_row(
         guard_base_args,
         base_args,
         permission_args,
         system_prompts,
         question_phrases,
         runner_image,
         credential_kinds
       ) do
    repo().query!(
      """
      UPDATE agents
         SET base_args = $1::text[],
             permission_args_by_stage = $2::text::jsonb,
             system_prompt_by_stage = $3::text::jsonb,
             question_phrases = $4::text[],
             runner_image = $5,
             required_credential_kinds = $6::text[]
       WHERE slug = 'codex'
         AND base_args = $7::text[]
      """,
      [
        base_args,
        Jason.encode!(permission_args),
        Jason.encode!(system_prompts),
        question_phrases,
        runner_image,
        credential_kinds,
        guard_base_args
      ]
    )
  end

  defp seed_template(slug, name, body, description) do
    repo().query!(
      """
      INSERT INTO prompt_templates (slug, name, body, description)
      SELECT $1, $2, $3, $4
       WHERE NOT EXISTS (
         SELECT 1 FROM prompt_templates
          WHERE slug = $1
            AND project_id IS NULL
            AND user_id IS NULL
       )
      """,
      [slug, name, body, description]
    )
  end

  defp unseed_template(slug, seeded_body) do
    repo().query!(
      """
      DELETE FROM prompt_templates
       WHERE project_id IS NULL
         AND user_id IS NULL
         AND slug = $1
         AND body = $2
      """,
      [slug, seeded_body]
    )
  end
end
