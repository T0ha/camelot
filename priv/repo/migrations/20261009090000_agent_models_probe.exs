defmodule Camelot.Repo.Migrations.AgentModelsProbe do
  @moduledoc """
  Adds `agents.models_probe` and backfills the two seeded rows.

  `available_models` is a global, hand-maintained column, but the set
  of ids a CLI accepts is scoped to the *credential* that will run the
  task — see `20260924080000_codex_available_models.exs`, which pinned
  three ids verified against a ChatGPT account on an install that
  authenticates Codex with an API key. `models_probe` says how to ask
  the provider instead (`Camelot.Agents.ModelDiscovery`), per user, at
  render time.

  The backfill is guarded on `models_probe IS NULL`, so an admin who
  has already edited the column at `/agents` is never overwritten —
  the same idiom as the codex models migration. `available_models` is
  left exactly as it is: it is now the offline fallback, and nothing
  in the feature ever writes it automatically.
  """

  use Ecto.Migration

  alias Camelot.Agents.ClaudeCodeDefaults
  alias Camelot.Agents.CodexDefaults

  def up do
    alter table(:agents) do
      add(:models_probe, :map)
    end

    flush()

    backfill("claude_code", ClaudeCodeDefaults.models_probe())
    backfill("codex", CodexDefaults.models_probe())
  end

  def down do
    alter table(:agents) do
      remove(:models_probe)
    end
  end

  defp backfill(slug, probe) do
    repo().query!(
      """
      UPDATE agents
         SET models_probe = $1::jsonb
       WHERE slug = $2
         AND models_probe IS NULL
      """,
      [probe, slug]
    )
  end
end
