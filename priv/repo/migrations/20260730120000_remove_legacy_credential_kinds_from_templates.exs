defmodule Camelot.Repo.Migrations.RemoveLegacyCredentialKindsFromTemplates do
  @moduledoc """
  PR #75 dropped `github_pat`/`github_oauth` from the set of valid
  credential kinds and cleaned up `credentials` rows of those kinds,
  but left any `agent_templates.required_credential_kinds` array
  still listing them untouched. Since those atoms no longer exist
  anywhere in the compiled app, `String.to_existing_atom/1` fails
  loading such a row, permanently breaking task dispatch for any
  agent using that template. Strip the retired kinds from the array
  instead of deleting the template. One-way: no meaningful `down`.
  """

  use Ecto.Migration

  def up do
    execute("""
    UPDATE agent_templates
    SET required_credential_kinds =
      array_remove(array_remove(required_credential_kinds, 'github_pat'), 'github_oauth')
    WHERE required_credential_kinds && ARRAY['github_pat', 'github_oauth']
    """)
  end

  def down do
    :ok
  end
end
