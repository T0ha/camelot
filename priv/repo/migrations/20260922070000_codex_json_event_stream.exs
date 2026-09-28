defmodule Camelot.Repo.Migrations.CodexJsonEventStream do
  @moduledoc """
  Switches the `codex` agent row onto `codex exec --json` and the
  `:codex_jsonl` parser.

  `20260922060000_fix_codex_for_modern_cli.exs` got the CLI running
  again but left `parser = 'raw_text'`, which stores the run's entire
  human-readable transcript as its result. The first successful
  planning run therefore produced a 122 KB "plan": the echoed prompt,
  every `rg`/`sed` command the agent ran, and every line those commands
  printed, with the actual plan as the last few hundred lines.

  With `--json` the CLI emits one event per line and the agent's own
  messages arrive as `item.completed` events whose item `type` is
  `agent_message`, which is all `Camelot.Runtime.OutputParser` keeps.

  Guarded on `base_args` still being exactly what that migration wrote,
  so a row since customised at `/agents` is left alone — the same
  exact-value precedent it followed.
  """

  use Ecto.Migration

  @old_base_args ["exec", "--skip-git-repo-check", "--color", "never"]
  @new_base_args ["exec", "--json", "--skip-git-repo-check", "--color", "never"]

  @old_planning_body "You are in planning mode: investigate the " <>
                       "repository read-only and do not modify, " <>
                       "create, or delete any file. End your final " <>
                       "message with the complete implementation plan " <>
                       "in Markdown — that message is captured verbatim " <>
                       "as the plan for approval. If you instead need " <>
                       "input or a decision before the plan can be " <>
                       "finished, reply with nothing but your questions, " <>
                       "one per line, in under 400 characters."

  @new_planning_body "You are in planning mode: investigate the " <>
                       "repository read-only and do not modify, " <>
                       "create, or delete any file. Your final message " <>
                       "must be the complete implementation plan in " <>
                       "Markdown and nothing else — no preamble, no " <>
                       "narration of what you are about to do, no " <>
                       "summary of what you read. It is captured as the " <>
                       "plan for approval exactly as you write it. If " <>
                       "you instead need input or a decision before the " <>
                       "plan can be finished, reply with nothing but " <>
                       "your questions, one per line, in under 400 " <>
                       "characters."

  def up do
    switch_row(@old_base_args, @new_base_args, "codex_jsonl")
    retext_planning_prompt(@old_planning_body, @new_planning_body)
  end

  def down do
    switch_row(@new_base_args, @old_base_args, "raw_text")
    retext_planning_prompt(@new_planning_body, @old_planning_body)
  end

  defp switch_row(guard_base_args, base_args, parser) do
    repo().query!(
      """
      UPDATE agents
         SET base_args = $1::text[],
             parser = $2
       WHERE slug = 'codex'
         AND base_args = $3::text[]
      """,
      [base_args, parser, guard_base_args]
    )
  end

  # The planning prompt no longer has to fight a verbatim-transcript
  # capture, so it asks for the plan alone instead of "end your final
  # message with" it. Only rewritten while the row still holds the text
  # the previous migration seeded, so an edit made at /prompts survives.
  defp retext_planning_prompt(old_body, new_body) do
    repo().query!(
      """
      UPDATE prompt_templates
         SET body = $1
       WHERE slug = 'codex_planning_system_prompt'
         AND project_id IS NULL
         AND user_id IS NULL
         AND body = $2
      """,
      [new_body, old_body]
    )
  end
end
