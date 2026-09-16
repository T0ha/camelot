defmodule CamelotWeb.AuthController do
  @moduledoc """
  Handles authentication callbacks from
  AshAuthentication strategies.
  """
  use CamelotWeb, :controller
  use AshAuthentication.Phoenix.Controller

  alias AshAuthentication.Errors.AuthenticationFailed
  alias Camelot.Accounts.Errors.RegistrationDisabled
  alias Camelot.Accounts.User
  alias Camelot.Github.UserInstallations
  alias CamelotWeb.GithubLoginFlow

  require Logger

  @spec success(
          Plug.Conn.t(),
          {atom(), atom()},
          Ash.Resource.record(),
          String.t() | nil
        ) :: Plug.Conn.t()
  def success(conn, {:github, :callback}, %User{} = user, _token) do
    :telemetry.execute([:camelot, :user, :signed_in], %{}, %{user: user})
    sync_github_installations(user)

    conn
    |> store_in_session(user)
    |> assign(:current_user, user)
    |> put_pending_github_email(user)
    |> GithubLoginFlow.next_step(user)
  end

  def success(conn, _activity, user, _token) do
    :telemetry.execute([:camelot, :user, :signed_in], %{}, %{user: user})

    conn
    |> store_in_session(user)
    |> assign(:current_user, user)
    |> redirect(to: ~p"/")
  end

  @spec failure(
          Plug.Conn.t(),
          {atom(), atom()},
          any()
        ) :: Plug.Conn.t()
  def failure(conn, _activity, reason) do
    conn
    |> put_flash(:error, failure_message(reason))
    |> redirect(to: ~p"/sign-in")
  end

  @spec sign_out(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def sign_out(conn, _params) do
    conn
    |> clear_session(:camelot)
    |> redirect(to: ~p"/sign-in")
  end

  # Folding the App installation into the login round-trip is
  # the whole point of the feature: a new user lands on the
  # board connected, with no second step on /profile. Failure
  # is non-fatal — they are signed in either way, and
  # GithubLoginFlow sends them to GitHub's install page.
  defp sync_github_installations(user) do
    user.__metadata__
    |> Map.get(:github_access_token)
    |> UserInstallations.sync(user)
    |> case do
      :ok -> :ok
      {:error, reason} -> log_sync_failure(user, reason)
    end
  rescue
    error ->
      log_sync_failure(user, error)
  end

  # Nothing to sync isn't a failure: the deployment simply has
  # no GitHub App, or GitHub handed us no user token.
  defp log_sync_failure(_user, reason) when reason in [:not_configured, :no_access_token], do: :ok

  defp log_sync_failure(user, reason) do
    Logger.warning(
      "GitHub login: could not sync installations for user " <>
        "#{user.id}: #{inspect(reason)}"
    )

    :ok
  end

  defp put_pending_github_email(conn, user) do
    case user.__metadata__[:pending_github_email] do
      nil -> conn
      email -> put_session(conn, GithubLoginFlow.pending_email_key(), email)
    end
  end

  defp failure_message(reason) do
    if invite_only?(reason) do
      RegistrationDisabled.text()
    else
      "Authentication failed"
    end
  end

  defp invite_only?(%RegistrationDisabled{}), do: true

  defp invite_only?(%AuthenticationFailed{caused_by: caused_by}), do: invite_only?(caused_by)

  defp invite_only?(%{errors: errors}), do: invite_only?(errors)

  defp invite_only?(errors) when is_list(errors), do: Enum.any?(errors, &invite_only?/1)

  defp invite_only?(_reason), do: false
end
