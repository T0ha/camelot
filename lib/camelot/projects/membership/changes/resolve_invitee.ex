defmodule Camelot.Projects.Membership.Changes.ResolveInvitee do
  @moduledoc """
  Authorizes and resolves the invitee for `Membership.:invite`,
  running before the insert inside the same transaction:

  1. the actor must be a global admin or already `role: :owner`
     on the target project, otherwise the changeset fails with a
     clear error instead of hitting the database.
  2. looks up (or creates, via `User.:create_user`) the `User`
     for the given email. Reusing `:create_user` unmodified keeps
     this immune to the duplicate-confirmation-email bug fixed in
     `d867153` — `SendInvitationEmail` fires exactly as it does
     for the admin `/admin/users` page.
  3. rejects the invite if the resolved user is already a member
     of the project, instead of hitting the composite-PK unique
     constraint.

  Stashes the resolved `User` in changeset context under
  `:invitee` for `SendProjectInviteEmail` to use, and force-sets
  `project_id`/`user_id`/`role` on the changeset.
  """
  use Ash.Resource.Change

  alias Camelot.Accounts.User
  alias Camelot.Projects.Membership

  require Ash.Query

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &resolve/1)
  end

  defp resolve(changeset) do
    actor = changeset.context[:private][:actor] || changeset.context[:actor]
    project_id = Ash.Changeset.get_argument(changeset, :project_id)
    email = Ash.Changeset.get_argument(changeset, :email)
    role = Ash.Changeset.get_argument(changeset, :role) || :member

    with :ok <- authorize(actor, project_id),
         {:ok, user} <- find_or_create_user(email, actor),
         :ok <- ensure_not_member(project_id, user.id) do
      changeset
      |> Ash.Changeset.force_change_attribute(:project_id, project_id)
      |> Ash.Changeset.force_change_attribute(:user_id, user.id)
      |> Ash.Changeset.force_change_attribute(:role, role)
      |> Ash.Changeset.put_context(:invitee, user)
    else
      {:error, message} when is_binary(message) ->
        Ash.Changeset.add_error(changeset, field: :project_id, message: message)

      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)
    end
  end

  defp authorize(%User{role: :admin}, _project_id), do: :ok

  defp authorize(%User{id: user_id}, project_id) when is_binary(project_id) do
    if Membership.owner?(project_id, user_id) do
      :ok
    else
      {:error, "You must be an admin or the project's owner to invite members."}
    end
  end

  defp authorize(_actor, _project_id) do
    {:error, "You must be an admin or the project's owner to invite members."}
  end

  defp find_or_create_user(email, actor) do
    User
    |> Ash.Query.filter(email == ^email)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %User{} = user} ->
        {:ok, user}

      {:ok, nil} ->
        User
        |> Ash.Changeset.for_create(
          :create_user,
          %{email: email, role: :user},
          actor: actor,
          authorize?: false
        )
        |> Ash.create()

      {:error, error} ->
        {:error, error}
    end
  end

  defp ensure_not_member(project_id, user_id) do
    Membership
    |> Ash.Query.filter(project_id == ^project_id and user_id == ^user_id)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> :ok
      {:ok, %Membership{}} -> {:error, "This user is already a member of this project."}
      {:error, error} -> {:error, error}
    end
  end
end
