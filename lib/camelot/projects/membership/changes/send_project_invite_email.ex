defmodule Camelot.Projects.Membership.Changes.SendProjectInviteEmail do
  @moduledoc """
  Sends a project-specific "you've been added to `<project>`"
  email after a `Membership.:invite` succeeds.

  Sent to both brand-new and pre-existing invitees. For a
  brand-new user this is intentionally their second email — the
  account-ready invite already fired from `User.:create_user`
  inside `ResolveInvitee`, and this one carries distinct content,
  not a repeat of the duplicate-email bug fixed in `d867153`.

  Delivery failure is non-fatal: the membership is created either way.
  """
  use Ash.Resource.Change

  alias Camelot.Projects.Membership.Senders.SendProjectInviteEmail
  alias Camelot.Projects.Project

  require Logger

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, membership ->
      _ = safely_deliver(changeset, membership)
      {:ok, membership}
    end)
  end

  defp safely_deliver(changeset, membership) do
    user = changeset.context[:invitee]
    project = Ash.get!(Project, membership.project_id, authorize?: false)

    SendProjectInviteEmail.deliver(user, project)
  rescue
    error ->
      Logger.warning(
        "SendProjectInviteEmail: delivery failed for membership " <>
          "#{membership.project_id}/#{membership.user_id} — " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      {:error, error}
  end
end
