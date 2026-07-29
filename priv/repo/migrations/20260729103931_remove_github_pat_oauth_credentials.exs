defmodule Camelot.Repo.Migrations.RemoveGithubPatOauthCredentials do
  @moduledoc """
  Deletes stale `credentials` rows of kind `github_pat`/
  `github_oauth` now that GitHub auth is App-token/SSH
  only. There's no DB check constraint on `kind` — Ash's
  `one_of` constraint enforces valid kinds at the
  application layer — so leftover rows of a removed kind
  wouldn't be rejected by Postgres, only by Ash reads.
  One-way: no meaningful `down`.
  """

  use Ecto.Migration

  def up do
    execute("DELETE FROM credentials WHERE kind IN ('github_pat', 'github_oauth')")
  end

  def down do
    :ok
  end
end
