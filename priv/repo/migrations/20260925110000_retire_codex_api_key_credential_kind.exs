defmodule Camelot.Repo.Migrations.RetireCodexApiKeyCredentialKind do
  @moduledoc """
  Retires the `codex_api_key` credential kind in favour of
  `openai_api_key`, converting any stored row.

  The two were interchangeable everywhere they were consumed —
  `Camelot.Runtime.Runner.SecretEnv.to_env/1` mounted both as
  `OPENAI_API_KEY`, and `runner-images/base/entrypoint.sh` collapsed
  them in the same `case` arm — yet the profile page offered them as
  separate choices with nothing to tell them apart. That made a
  cosmetic decision load-bearing: `20260922060000` had the `codex`
  agent require `codex_api_key`, a user stored their key under
  `openai_api_key`, `TaskRunner.build_secrets/2` found nothing for the
  declared kind, and every run failed with

      401 Unauthorized: Missing bearer or basic authentication in header

  which reads as a bad key rather than a missing one.

  Kinds name the **provider**, not the agent CLI that reads them —
  `claude_api_key`, not `claude_code_api_key` — so `openai_api_key` is
  the one that survives. A future ChatGPT-token path would discriminate
  on the value inside one kind, exactly as `claude_api_key` already
  does for `sk-ant-oat*`.

  ## Conversion

  Rows are re-kinded, never deleted, and marked
  `metadata.migrated_from` so `down` can reverse precisely the rows
  `up` touched (a plain conversion is otherwise indistinguishable from
  a credential that was always `openai_api_key`).

  `credentials` is unique on `(user_id, kind, name)`, so a user who
  held both kinds under the same name would collide. Those rows keep
  both values and get a disambiguating name rather than losing a
  secret — the id fragment guarantees the new name can't collide
  either. `down` restores the kind but not the name; the marker in
  `metadata` says where it came from.

  `Camelot.Agents.CredentialKinds` drops unknown kinds when loading a
  row, so an `agents` row still naming the retired kind stays loadable
  either way — but fix them too, so nothing declares a requirement no
  credential can satisfy.
  """

  use Ecto.Migration

  def up do
    convert_credentials()
    set_agent_kinds("codex_api_key", "openai_api_key")
  end

  def down do
    revert_credentials()
    set_agent_kinds("openai_api_key", "codex_api_key")
  end

  defp convert_credentials do
    execute("""
    UPDATE credentials c
       SET kind = 'openai_api_key',
           metadata =
             coalesce(c.metadata, '{}'::jsonb)
               || '{"migrated_from":"codex_api_key"}'::jsonb,
           name =
             CASE
               WHEN EXISTS (
                 SELECT 1 FROM credentials o
                  WHERE o.user_id = c.user_id
                    AND o.kind = 'openai_api_key'
                    AND o.name IS NOT DISTINCT FROM c.name
               )
               THEN coalesce(c.name || ' ', '')
                      || '(was codex_api_key ' || left(c.id::text, 8) || ')'
               ELSE c.name
             END,
           updated_at = timezone('utc', now())
     WHERE c.kind = 'codex_api_key'
    """)
  end

  defp revert_credentials do
    execute("""
    UPDATE credentials
       SET kind = 'codex_api_key',
           metadata = metadata - 'migrated_from',
           updated_at = timezone('utc', now())
     WHERE kind = 'openai_api_key'
       AND metadata ->> 'migrated_from' = 'codex_api_key'
    """)
  end

  # Rewrites the kind inside the `required_credential_kinds` text[]
  # wherever it appears, deduping in case both are already listed.
  defp set_agent_kinds(from, to) do
    execute("""
    UPDATE agents
       SET required_credential_kinds = (
             SELECT array_agg(DISTINCT replace(k, '#{from}', '#{to}'))
               FROM unnest(required_credential_kinds) AS k
           )
     WHERE '#{from}' = ANY(required_credential_kinds)
    """)
  end
end
