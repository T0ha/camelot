defmodule Camelot.Repo.Migrations.AddAntigravityAgent do
  @moduledoc """
  Adds the built-in `antigravity` agent template (Google Antigravity
  CLI, `agy`) and the three `PromptTemplate` rows its
  `system_prompt_by_stage` placeholders resolve against.

  Values come from `Camelot.Agents.AntigravityDefaults`, following
  `20261009090000_agent_models_probe.exs`, so the seeded row, the seed
  script and the regression tests read one source.

  Both halves are guarded so a hand-customised install survives:

    * the agent row and the templates insert under `WHERE NOT EXISTS`,
      so an install that already created an `antigravity` row (or an
      `agy_*` template) at `/agents` or `/prompts` is left alone;

    * `down` only deletes a template whose body still matches what
      `up` wrote, and only deletes the agent row while nothing
      references it.
  """

  use Ecto.Migration

  alias Camelot.Agents.AntigravityDefaults

  @slug "antigravity"

  def up do
    seed_template(
      AntigravityDefaults.planning_system_prompt_slug(),
      "Antigravity Planning System Prompt",
      AntigravityDefaults.planning_system_prompt(),
      "Prepended to the prompt during the planning stage — agy has " <>
        "no --append-system-prompt flag. Plain text, no {{variable}} " <>
        "interpolation."
    )

    seed_template(
      AntigravityDefaults.execution_system_prompt_slug(),
      "Antigravity Execution System Prompt",
      AntigravityDefaults.execution_system_prompt(),
      "Prepended to the prompt during the executing stage. Plain " <>
        "text, no {{variable}} interpolation."
    )

    seed_template(
      AntigravityDefaults.pr_system_prompt_slug(),
      "Antigravity PR Review System Prompt",
      AntigravityDefaults.pr_system_prompt(),
      "Prepended to the prompt during the pr-review stage. Plain " <>
        "text, no {{variable}} interpolation."
    )

    insert_agent()
  end

  def down do
    repo().query!(
      """
      DELETE FROM agents a
       WHERE a.slug = $1
         AND NOT EXISTS (SELECT 1 FROM tasks WHERE agent_id = a.id)
         AND NOT EXISTS (SELECT 1 FROM sessions WHERE agent_id = a.id)
         AND NOT EXISTS (SELECT 1 FROM env_vars WHERE agent_id = a.id)
      """,
      [@slug]
    )

    unseed_template(
      AntigravityDefaults.planning_system_prompt_slug(),
      AntigravityDefaults.planning_system_prompt()
    )

    unseed_template(
      AntigravityDefaults.execution_system_prompt_slug(),
      AntigravityDefaults.execution_system_prompt()
    )

    unseed_template(
      AntigravityDefaults.pr_system_prompt_slug(),
      AntigravityDefaults.pr_system_prompt()
    )
  end

  defp insert_agent do
    repo().query!(
      """
      INSERT INTO agents (
        slug, name, executable, base_args, prompt_flag, model_flag,
        available_models, default_model, models_probe,
        permission_args_by_stage, system_prompt_by_stage, parser,
        question_phrases, runner_image, required_credential_kinds
      )
      SELECT $1, $2, $3, $4::text[], $5, $6, $7::text[], $8, $9::jsonb,
             $10::jsonb, $11::jsonb, $12, $13::text[], $14, $15::text[]
       WHERE NOT EXISTS (SELECT 1 FROM agents WHERE slug = $1)
      """,
      [
        @slug,
        "Antigravity",
        "agy",
        AntigravityDefaults.base_args(),
        AntigravityDefaults.prompt_flag(),
        AntigravityDefaults.model_flag(),
        AntigravityDefaults.available_models(),
        AntigravityDefaults.default_model(),
        AntigravityDefaults.models_probe(),
        AntigravityDefaults.permission_args_by_stage(),
        AntigravityDefaults.system_prompt_by_stage(),
        Atom.to_string(AntigravityDefaults.parser()),
        AntigravityDefaults.question_phrases(),
        AntigravityDefaults.runner_image(),
        Enum.map(AntigravityDefaults.required_credential_kinds(), &Atom.to_string/1)
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
