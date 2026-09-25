defmodule Camelot.Repo.Migrations.CodexPlanningOutputSchema do
  @moduledoc """
  Puts the `codex` planning run on a structured-output contract.

  `20260922070000_codex_json_event_stream.exs` made the run readable,
  but the plan-or-question decision was still inferred from prose: the
  final message became the plan unless it happened to be short enough
  and to match a `question_phrases` entry. Codex's `--output-schema`
  is the analogue of the `--json-schema` contract `claude_code` has
  had since `docs/planning-output-contract.md` — the final message is
  then a validated object and `TaskRunner.planning_action/2` reads the
  decision directly.

  The schema is stored on the row rather than inline in the args
  because the flag takes a FILE: the app materialises it per run at
  `Runner.Spec.output_schema_path/1` and the `{{output_schema_path}}`
  placeholder in the planning args resolves to that path.

  Frozen literals, guarded on the values the previous migration wrote,
  per the precedent those migrations set — a row or prompt edited at
  `/agents` or `/prompts` is left alone.

  Note the schema's shape: Codex forwards it to OpenAI's *strict*
  structured-output mode, which requires `additionalProperties: false`
  and every property listed in `required`, so optional fields are
  nullable unions instead. The looser schema `claude_code` uses fails
  the turn with a 400 before the model runs.
  """

  use Ecto.Migration

  @old_planning_args ["--sandbox", "read-only"]
  @new_planning_args ["--sandbox", "read-only", "--output-schema", "{{output_schema_path}}"]

  @schema %{
    "type" => "object",
    "additionalProperties" => false,
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
        "type" => ["string", "null"],
        "description" =>
          ~s(The full implementation plan in Markdown. Required when ) <>
            ~s(decision is "plan"; null otherwise.)
      },
      "questions" => %{
        "type" => ["array", "null"],
        "items" => %{"type" => "string"},
        "description" =>
          ~s(One clarifying question per item. Required when decision ) <>
            ~s(is "question"; null otherwise.)
      }
    },
    "required" => ["decision", "plan", "questions"]
  }

  @old_planning_body "You are in planning mode: investigate the " <>
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

  @new_planning_body "You are in planning mode: investigate the " <>
                       "repository read-only and do not modify, " <>
                       "create, or delete any file. Your final message " <>
                       "is validated against a JSON Schema. Set " <>
                       ~s(decision="plan" with the complete ) <>
                       "implementation plan in Markdown under `plan` " <>
                       "when you are ready for approval, or " <>
                       ~s(decision="question" with specific questions ) <>
                       "under `questions` when you need input or a " <>
                       "decision before planning can complete. Leave " <>
                       "the field you are not using null."

  def up do
    set_planning_args(@old_planning_args, @new_planning_args)
    set_output_schema(%{"planning" => Jason.encode!(@schema)})
    retext_planning_prompt(@old_planning_body, @new_planning_body)
  end

  def down do
    set_planning_args(@new_planning_args, @old_planning_args)
    set_output_schema(%{})
    retext_planning_prompt(@new_planning_body, @old_planning_body)
  end

  defp set_planning_args(guard_args, args) do
    repo().query!(
      """
      UPDATE agents
         SET permission_args_by_stage =
               jsonb_set(permission_args_by_stage, '{planning}', $1::text::jsonb)
       WHERE slug = 'codex'
         AND permission_args_by_stage -> 'planning' = $2::text::jsonb
      """,
      [Jason.encode!(args), Jason.encode!(guard_args)]
    )
  end

  # Unguarded: the column is new, so every existing row holds the `{}`
  # default and there is no user edit to preserve yet.
  defp set_output_schema(value) do
    repo().query!(
      "UPDATE agents SET output_schema_by_stage = $1::text::jsonb WHERE slug = 'codex'",
      [Jason.encode!(value)]
    )
  end

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
