defmodule Camelot.Repo.Migrations.CodexAcceptsOpenaiApiKey do
  @moduledoc """
  Lets the `codex` row's auth be satisfied by an `openai_api_key`
  credential, not only a `codex_api_key` one.

  `20260922060000_fix_codex_for_modern_cli.exs` declared
  `{codex_api_key}`. But `Camelot.Runtime.Runner.SecretEnv` maps both
  that and `openai_api_key` to the same `OPENAI_API_KEY` variable, and
  the profile page offers the two as separate choices with nothing to
  tell them apart — so a user who stored their OpenAI key under the
  obvious `openai_api_key` had `TaskRunner.build_secrets/2` find
  nothing for the declared kind, log a warning, and dispatch anyway.
  Codex then failed every attempt with

      401 Unauthorized: Missing bearer or basic authentication in header

  which reads as a bad key rather than a missing one. Seen on the test
  cluster; the first real Codex run there died this way four times.

  `build_secrets/2` now dedupes by `SecretEnv.canonical_kind/1`, so
  declaring both accepts whichever the user stored without a user
  holding both mounting two values for one variable. `openai_api_key`
  goes first: it is the one the profile page's naming steers people to.

  Guarded on the exact value the earlier migration wrote, so a row
  customised at `/agents` is left alone.
  """

  use Ecto.Migration

  @old_kinds ["codex_api_key"]
  @new_kinds ["openai_api_key", "codex_api_key"]

  def up, do: set_kinds(@new_kinds, @old_kinds)

  def down, do: set_kinds(@old_kinds, @new_kinds)

  defp set_kinds(kinds, guard_kinds) do
    repo().query!(
      """
      UPDATE agents
         SET required_credential_kinds = $1::text[]
       WHERE slug = 'codex'
         AND required_credential_kinds = $2::text[]
      """,
      [kinds, guard_kinds]
    )
  end
end
