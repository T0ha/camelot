defmodule Camelot.Repo.Migrations.ClaudeAppendSystemPromptPlaceholders do
  @moduledoc """
  Backfills already-migrated `agents` rows so the `claude_code`
  template's planning/executing `--append-system-prompt` values switch
  from the literal hardcoded text to `{{prompt:<slug>}}` placeholders
  (resolved at dispatch time by
  `Camelot.Runtime.AgentConfig.render_permission_args/3` against the
  `PromptTemplate` rows seeded by
  `20260831120000_seed_claude_system_prompt_templates.exs`), and adds a
  `"pr"` key that never existed before.

  For planning/executing this follows the exact-value guard precedent
  of `20260706120000_claude_stream_json_base_args.exs` rather than the
  looser "flag missing" guard used by
  `20260709120000`/`20260713120000` — those were safe only because the
  feature they introduced didn't exist yet for anyone to have
  customized around. `--append-system-prompt` text can already have
  been hand-edited via `/agents`, so an exact match avoids clobbering
  that.

  For pr there is no existing key to match against
  (`permission_args_by_stage` has no `"pr"` entry on any row today), so
  the guard is instead "key absent" via the jsonb `?` operator, adding
  the key with `jsonb_set(..., true)` rather than replacing it.

  Fresh installs never run this migration's `up`/`down` bodies against
  real data (both guards no-op once `ClaudeCodeDefaults.
  permission_args_by_stage/0` already returns the placeholder shape,
  which is what `priv/repo/seeds.exs` and the earlier
  `20260709120000`/`20260713120000` migrations pick up live) — this
  migration exists purely to backfill databases migrated before this
  change.
  """

  use Ecto.Migration

  alias Camelot.Agents.ClaudeCodeDefaults

  def up do
    rewrite_existing_stage("planning", old_planning_args(), new_planning_args())
    rewrite_existing_stage("executing", old_executing_args(), new_executing_args())
    add_missing_pr_stage(new_pr_args())
  end

  def down do
    rewrite_existing_stage("planning", new_planning_args(), old_planning_args())
    rewrite_existing_stage("executing", new_executing_args(), old_executing_args())
    remove_pr_stage(new_pr_args())
  end

  defp rewrite_existing_stage(stage, old_args, new_args) do
    repo().query!(
      """
      UPDATE agents
      SET permission_args_by_stage =
        jsonb_set(permission_args_by_stage, $1::text[], $2::text::jsonb)
      WHERE slug = 'claude_code'
        AND permission_args_by_stage -> $3 = $4::text::jsonb
      """,
      [[stage], Jason.encode!(new_args), stage, Jason.encode!(old_args)]
    )
  end

  defp add_missing_pr_stage(pr_args) do
    repo().query!(
      """
      UPDATE agents
      SET permission_args_by_stage =
        jsonb_set(permission_args_by_stage, '{pr}', $1::text::jsonb, true)
      WHERE slug = 'claude_code'
        AND NOT (permission_args_by_stage ? 'pr')
      """,
      [Jason.encode!(pr_args)]
    )
  end

  defp remove_pr_stage(pr_args) do
    repo().query!(
      """
      UPDATE agents
      SET permission_args_by_stage = permission_args_by_stage - 'pr'
      WHERE slug = 'claude_code'
        AND permission_args_by_stage -> 'pr' = $1::text::jsonb
      """,
      [Jason.encode!(pr_args)]
    )
  end

  # Frozen literals — calling ClaudeCodeDefaults' *_system_prompt/0
  # accessors directly is fine and intended, those stay stable per
  # this migration and remain the backfill source of truth.
  defp old_planning_args do
    [
      "--permission-mode",
      "plan",
      "--append-system-prompt",
      ClaudeCodeDefaults.planning_system_prompt(),
      "--json-schema",
      ClaudeCodeDefaults.planning_json_schema()
    ]
  end

  defp old_executing_args do
    [
      "--permission-mode",
      "acceptEdits",
      "--append-system-prompt",
      ClaudeCodeDefaults.execution_system_prompt()
    ]
  end

  defp new_planning_args do
    [
      "--permission-mode",
      "plan",
      "--append-system-prompt",
      "{{prompt:#{ClaudeCodeDefaults.planning_system_prompt_slug()}}}",
      "--json-schema",
      ClaudeCodeDefaults.planning_json_schema()
    ]
  end

  defp new_executing_args do
    [
      "--permission-mode",
      "acceptEdits",
      "--append-system-prompt",
      "{{prompt:#{ClaudeCodeDefaults.execution_system_prompt_slug()}}}"
    ]
  end

  defp new_pr_args do
    [
      "--append-system-prompt",
      "{{prompt:#{ClaudeCodeDefaults.pr_system_prompt_slug()}}}"
    ]
  end
end
