defmodule Camelot.Repo.Migrations.RequireClaudeApiKeyForClaudeCode do
  @moduledoc """
  Fills in the `claude_code` row's `required_credential_kinds`, which
  has been empty in every deployment since the column was added with
  `default: []` by `20260602100833_add_runner_resources.exs`.

  Nothing ever backfilled it: the only other migrations touching the
  column are the two legacy-kind cleanups and
  `20260922060000_fix_codex_for_modern_cli.exs`, which sets it for
  `codex` alone, and `priv/repo/seeds.exs` passed
  `CodexDefaults.required_credential_kinds()` for codex while
  `claude_code_attrs` had no such key at all.

  `Camelot.Runtime.TaskRunner.build_secrets/2` iterates this list, so
  an empty one meant the user's `claude_api_key` was never mounted and
  neither `ANTHROPIC_API_KEY` nor `CLAUDE_CODE_OAUTH_TOKEN` reached
  the runner (`Camelot.Runtime.Runner.SecretEnv`). The run then failed
  with a bare 401 from the CLI, without even logging the "missing
  credential" warning — nothing had been asked for. It worked only
  where an admin had typed the kind into `/agents/:id/edit` by hand.

  Both directions are guarded on the value they expect to replace, so
  that hand-entered value is never clobbered either way.
  """

  use Ecto.Migration

  @kinds ["claude_api_key"]

  def up, do: set_kinds(@kinds, [])

  def down, do: set_kinds([], @kinds)

  defp set_kinds(kinds, guard_kinds) do
    repo().query!(
      """
      UPDATE agents
         SET required_credential_kinds = $1::text[]
       WHERE slug = 'claude_code'
         AND required_credential_kinds = $2::text[]
      """,
      [kinds, guard_kinds]
    )
  end
end
