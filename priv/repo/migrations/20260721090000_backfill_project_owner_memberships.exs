defmodule Camelot.Repo.Migrations.BackfillProjectOwnerMemberships do
  @moduledoc """
  Promote each project's creator to `role: :owner`.

  `Camelot.Projects.Project.Changes.AddActorAsMember` only started
  assigning `:owner` on 2026-07-13; projects created before that (and
  legacy projects backfilled by hand) can have their creator recorded
  as a plain `:member`. `Project.owner_membership` filters on
  `role == :owner`, so those projects resolve no owner — which makes
  `Camelot.Runtime.AgentProcess.node_label_for/1` skip the owner's
  swarm-node pin and schedule tasks unconstrained.

  For every project that has no owner yet, promotes its earliest
  membership (the creator — added at project creation) to `:owner`.
  `DISTINCT ON` guarantees exactly one promotion per project even if
  two memberships share an `inserted_at`. Idempotent: projects that
  already have an owner are excluded, so re-running is a no-op.
  """
  use Ecto.Migration

  def up do
    repo().query!(
      """
      UPDATE project_memberships pm
      SET role = 'owner', updated_at = now()
      FROM (
        SELECT DISTINCT ON (m.project_id) m.project_id, m.user_id
        FROM project_memberships m
        WHERE NOT EXISTS (
          SELECT 1 FROM project_memberships o
          WHERE o.project_id = m.project_id AND o.role = 'owner'
        )
        ORDER BY m.project_id, m.inserted_at ASC, m.user_id ASC
      ) pick
      WHERE pm.project_id = pick.project_id
        AND pm.user_id = pick.user_id
      """,
      []
    )
  end

  # Not reversible: promoted owners are indistinguishable from owners
  # created normally, so we cannot know which rows to demote.
  def down, do: :ok
end
