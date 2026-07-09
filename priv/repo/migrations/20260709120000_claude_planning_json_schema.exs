defmodule Camelot.Repo.Migrations.ClaudePlanningJsonSchema do
  @moduledoc """
  Move the seeded `claude_code` template's planning stage onto the
  `--json-schema` structured-output contract. The runner's Claude Code
  (ToolSearch build) omits `ExitPlanMode` from the headless tool
  registry, so the plan/question is delivered via the injected
  `StructuredOutput` tool instead. See docs/planning-output-contract.md.

  Only rewrites rows still carrying the exact old value so a
  hand-customised template is left untouched.
  """
  use Ecto.Migration

  alias Camelot.Agents.ClaudeCodeDefaults

  # Only the planning key is rewritten (via jsonb_set), so `executing`
  # and any hand-customised stages are preserved. Idempotent: guarded on
  # whether the planning args already carry the `--json-schema` flag,
  # rather than an exact-value match.
  def up do
    new_planning = Jason.encode!(ClaudeCodeDefaults.permission_args_by_stage()["planning"])

    repo().query!(
      """
      UPDATE agent_templates
      SET permission_args_by_stage =
        jsonb_set(permission_args_by_stage, '{planning}', $1::text::jsonb)
      WHERE slug = 'claude_code'
        AND NOT (permission_args_by_stage -> 'planning' @> '["--json-schema"]'::jsonb)
      """,
      [new_planning]
    )
  end

  def down do
    repo().query!(
      """
      UPDATE agent_templates
      SET permission_args_by_stage =
        jsonb_set(permission_args_by_stage, '{planning}', '["--permission-mode","plan"]'::jsonb)
      WHERE slug = 'claude_code'
        AND permission_args_by_stage -> 'planning' @> '["--json-schema"]'::jsonb
      """,
      []
    )
  end
end
