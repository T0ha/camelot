defmodule Camelot.Repo.Migrations.ClaudeExecutionSystemPrompt do
  @moduledoc """
  Append an execution-stage system prompt to the seeded `claude_code`
  template. In a headless, single-turn `claude -p` run the agent used
  to spawn background tasks and end its turn to "wait for a
  notification", exiting cleanly without opening a PR. The appended
  `--append-system-prompt` steers it to run synchronously, never pause
  for approval, and always open the PR (printing its URL).

  Only rewrites the `{executing}` key (via jsonb_set) so hand-customised
  stages are preserved. Idempotent: guarded on whether the executing
  args already carry `--append-system-prompt`.
  """
  use Ecto.Migration

  alias Camelot.Agents.ClaudeCodeDefaults

  def up do
    new_executing =
      Jason.encode!(ClaudeCodeDefaults.permission_args_by_stage()["executing"])

    repo().query!(
      """
      UPDATE agent_templates
      SET permission_args_by_stage =
        jsonb_set(permission_args_by_stage, '{executing}', $1::text::jsonb)
      WHERE slug = 'claude_code'
        AND NOT (permission_args_by_stage -> 'executing' @> '["--append-system-prompt"]'::jsonb)
      """,
      [new_executing]
    )
  end

  def down do
    repo().query!(
      """
      UPDATE agent_templates
      SET permission_args_by_stage =
        jsonb_set(permission_args_by_stage, '{executing}', '["--permission-mode","acceptEdits"]'::jsonb)
      WHERE slug = 'claude_code'
        AND permission_args_by_stage -> 'executing' @> '["--append-system-prompt"]'::jsonb
      """,
      []
    )
  end
end
