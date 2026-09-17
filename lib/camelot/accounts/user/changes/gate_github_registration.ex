defmodule Camelot.Accounts.User.Changes.GateGithubRegistration do
  @moduledoc """
  Applies invite-only mode to GitHub sign-in.

  When `:registration_enabled` is `false`, a GitHub account
  that resolves to no existing Camelot user is refused
  instead of creating one. Existing users keep signing in
  normally — the same rule
  `CamelotWeb.Plugs.RegistrationGate` enforces for magic
  links.

  Runs as a `before_action` so it sees the lookup
  `Camelot.Accounts.User.Changes.ResolveGithubIdentity`
  already did, rather than querying again.
  """
  use Ash.Resource.Change

  alias Ash.Changeset
  alias Ash.Resource.Change
  alias Camelot.Accounts.Errors.RegistrationDisabled

  @impl Change
  @spec change(Changeset.t(), keyword(), Change.context()) ::
          Changeset.t()
  def change(changeset, _opts, _context) do
    Changeset.before_action(changeset, &gate/1)
  end

  defp gate(changeset) do
    registration_enabled? =
      Application.get_env(:camelot, :registration_enabled, true)

    gate(changeset, registration_enabled?, changeset.context[:github_existing_user])
  end

  defp gate(changeset, false, nil) do
    Changeset.add_error(changeset, RegistrationDisabled.exception([]))
  end

  defp gate(changeset, _registration_enabled?, _existing_user), do: changeset
end
