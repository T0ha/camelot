defmodule Camelot.Accounts.Errors.RegistrationDisabled do
  @moduledoc """
  Raised when a sign-in flow would have to create a brand new
  user while the instance runs in invite-only mode
  (`REGISTRATION_ENABLED=false`).

  Modelled as a `Splode.Error` so the auth controller can
  pattern-match it out of the nested
  `AshAuthentication.Errors.AuthenticationFailed` struct and
  show the same wording the magic-link gate uses.
  """
  use Splode.Error, fields: [], class: :forbidden

  @message "Registration is invite-only. Contact your administrator."

  @doc """
  The user-facing invite-only message. Shared with
  `CamelotWeb.Plugs.RegistrationGate` so both gates read alike.
  """
  @spec text() :: String.t()
  def text, do: @message

  @impl Exception
  def message(_error), do: @message
end
