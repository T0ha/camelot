defmodule Camelot.Accounts.User.Changes.SendInvitationEmail do
  @moduledoc """
  Sends a marketing-style invitation email after an admin creates a
  new user via `User.:create_user`.

  Not wired into the magic-link auto-upsert — self-registering users
  already know the platform exists, so they only get the token-bearing
  `SendMagicLink`/`SendConfirmationEmail` mail, not this one.

  Delivery failure is non-fatal: the user is created either way.
  """
  use Ash.Resource.Change

  alias Camelot.Accounts.User.Senders.SendInvitationEmail

  require Logger

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, user ->
      _ = safely_deliver(user)
      {:ok, user}
    end)
  end

  defp safely_deliver(user) do
    SendInvitationEmail.deliver(user)
  rescue
    error ->
      Logger.warning(
        "SendInvitationEmail: delivery failed for user #{user.id} — " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      {:error, error}
  end
end
