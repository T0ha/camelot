defmodule Camelot.Projects.Project.Changes.AddActorAsMember do
  @moduledoc """
  Inserts a `Camelot.Projects.Membership` row for the current actor
  after a project is created, so the creator can see their own
  project under the UI-layer scoping.

  No-ops when there is no actor (mix tasks, seeds, tests without
  `actor:`). Existing projects without memberships stay legacy —
  admins still see them via the "Showing: All" toggle.
  """
  use Ash.Resource.Change

  alias Camelot.Projects.Membership

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, &maybe_add_membership/2)
  end

  defp maybe_add_membership(changeset, project) do
    case changeset.context[:private][:actor] || changeset.context[:actor] do
      %{id: user_id} when is_binary(user_id) ->
        Membership
        |> Ash.Changeset.for_create(
          :create,
          %{project_id: project.id, user_id: user_id, role: :owner},
          authorize?: false
        )
        |> Ash.create!()

        {:ok, project}

      _ ->
        {:ok, project}
    end
  end
end
