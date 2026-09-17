defmodule CamelotWeb.GithubLoginFlow do
  @moduledoc """
  Decides where a just-signed-in GitHub user goes next.

  Shared by `CamelotWeb.AuthController` (straight off the
  OAuth callback) and `CamelotWeb.GithubEmailController`
  (after the user answers the email prompt), so both take
  the steps in the same order:

  1. GitHub reported a different verified email than the one
     on file → ask about it.
  2. The user has no App installation yet → send them to
     GitHub's install page, once.
  3. Otherwise → the board.

  Step 2 leaves a session flag behind so someone who
  declines the install isn't bounced to github.com on every
  single login.
  """
  use CamelotWeb, :verified_routes

  import Phoenix.Controller, only: [redirect: 2]
  import Plug.Conn

  alias Camelot.Accounts.User
  alias Camelot.Accounts.UserLookup
  alias Camelot.Github.AppConfig
  alias CamelotWeb.GithubSetupController

  @pending_email_key :github_pending_email
  @install_prompted_key :github_install_prompted

  @doc """
  Session key holding the verified GitHub address a user has
  yet to accept or reject. Written only by the auth
  callback, from an address GitHub reported as verified —
  never from user-supplied params.
  """
  @spec pending_email_key() :: atom()
  def pending_email_key, do: @pending_email_key

  @doc """
  Redirects `conn` to whichever step the sign-in still owes
  the user.
  """
  @spec next_step(Plug.Conn.t(), User.t()) :: Plug.Conn.t()
  def next_step(conn, %User{} = user) do
    if prompt_for_email?(conn, user) do
      redirect(conn, to: ~p"/github/email")
    else
      maybe_prompt_install(conn, user)
    end
  end

  defp prompt_for_email?(conn, user) do
    case get_session(conn, @pending_email_key) do
      nil -> false
      email -> adoptable?(user, email)
    end
  end

  @doc """
  Whether `email` is still worth offering to `user`: they
  haven't already declined it, and no other Camelot account
  holds it.
  """
  @spec adoptable?(User.t(), String.t()) :: boolean()
  def adoptable?(%User{} = user, email) do
    not declined?(user, email) and not taken_by_other?(user, email)
  end

  defp declined?(%User{github_email_declined: nil}, _email), do: false

  defp declined?(%User{github_email_declined: declined}, email) do
    downcase(declined) == downcase(email)
  end

  @doc """
  Whether `email` already belongs to a *different* Camelot
  user — in which case adopting it would collide.
  """
  @spec taken_by_other?(User.t(), String.t()) :: boolean()
  def taken_by_other?(%User{id: id}, email) do
    case UserLookup.fetch_by_email(email) do
      {:ok, %User{id: ^id}} -> false
      {:ok, %User{}} -> true
      :not_found -> false
    end
  end

  defp maybe_prompt_install(conn, user) do
    case installations(user) do
      {:ok, []} -> install_step(conn, user)
      _loaded_or_failed -> redirect(conn, to: ~p"/")
    end
  end

  defp installations(%User{github_installations: %Ash.NotLoaded{}} = user) do
    case Ash.load(user, :github_installations, actor: user) do
      {:ok, loaded} -> {:ok, loaded.github_installations}
      {:error, reason} -> {:error, reason}
    end
  end

  defp installations(%User{github_installations: installations}), do: {:ok, installations}

  defp install_step(conn, user) do
    case get_session(conn, @install_prompted_key) do
      nil -> redirect_to_install(conn, user)
      _already -> redirect(conn, to: ~p"/")
    end
  end

  defp redirect_to_install(conn, user) do
    case AppConfig.install_url(GithubSetupController.state_token(user.id)) do
      nil ->
        redirect(conn, to: ~p"/")

      url ->
        conn
        |> put_session(@install_prompted_key, true)
        |> redirect(external: url)
    end
  end

  defp downcase(value), do: value |> to_string() |> String.downcase()
end
