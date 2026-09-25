defmodule Camelot.Repo.Migrations.CodexAvailableModels do
  @moduledoc """
  Fills in the `codex` row's `available_models`, which
  `20260527063144_add_agent_templates.exs` left empty.

  The task form builds its Model dropdown from this column
  (`BoardLive.next_model_options/2`), so an empty list rendered only
  the "Use agent default" placeholder — the CLI ran on whatever model
  it picked for itself and there was no way to choose another.

  The CLI has no "list models" command. These three were established
  by invoking each candidate against codex-cli 0.155.0 and keeping the
  ones whose turn completed; `gpt-5.6-sol`, `gpt-5.4`, `gpt-5.3-codex`,
  `gpt-5.2` and `gpt-5.1-codex-max` came back 400 "not supported when
  using Codex with a ChatGPT account".

  That makes the list **account-scoped**, not a property of the CLI —
  another plan or API-key auth may accept a different set. Hence the
  guard: only a row still holding the empty default is filled, and
  `default_model` is left nil so the CLI keeps choosing its own rather
  than this migration pinning an id an install may not be entitled to.
  """

  use Ecto.Migration

  @models ["gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5"]

  def up, do: set_models(@models, [])

  def down, do: set_models([], @models)

  defp set_models(models, guard_models) do
    repo().query!(
      """
      UPDATE agents
         SET available_models = $1::text[]
       WHERE slug = 'codex'
         AND available_models = $2::text[]
      """,
      [models, guard_models]
    )
  end
end
