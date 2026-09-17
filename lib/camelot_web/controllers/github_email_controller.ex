defmodule CamelotWeb.GithubEmailController do
  @moduledoc """
  Asks a returning GitHub user whether to move their Camelot
  account to the new primary email GitHub now reports.

  Recognising the account by `github_user_id` is what makes
  this page possible — the user is already signed in as
  themselves, and nothing about their account has been
  changed. All this page does is offer the change.

  A plain controller rather than a LiveView because only a
  controller can *clear* the session key once the question
  has been answered.

  The candidate address is read from the session and never
  from params. The session value is written only by
  `CamelotWeb.AuthController`, from an address GitHub
  reported as verified — take it from the form instead and
  this becomes an endpoint for changing your email to
  anybody else's.
  """
  use CamelotWeb, :controller

  alias Camelot.Accounts.User
  alias CamelotWeb.GithubLoginFlow

  require Logger

  @spec edit(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def edit(conn, _params) do
    case pending(conn) do
      {:ok, user, email} ->
        render(conn, :edit,
          current_email: to_string(user.email),
          pending_email: email
        )

      {:error, step} ->
        redirect(conn, to: step)
    end
  end

  @spec update(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update(conn, params) do
    case pending(conn) do
      {:ok, user, email} -> decide(conn, user, email, params["decision"])
      {:error, step} -> redirect(conn, to: step)
    end
  end

  defp pending(conn) do
    user = conn.assigns[:current_user]
    email = get_session(conn, GithubLoginFlow.pending_email_key())

    case {user, email} do
      {nil, _} -> {:error, ~p"/sign-in"}
      {_user, nil} -> {:error, ~p"/"}
      {%User{} = user, email} -> {:ok, user, email}
    end
  end

  defp decide(conn, user, email, "update") do
    if GithubLoginFlow.taken_by_other?(user, email) do
      refuse_taken(conn, user)
    else
      adopt(conn, user, email)
    end
  end

  defp decide(conn, user, email, "keep") do
    case Ash.update(user, %{email: email},
           action: :decline_github_email,
           actor: user
         ) do
      {:ok, updated} ->
        conn
        |> put_flash(:info, "Keeping #{user.email}.")
        |> finish(updated)

      {:error, reason} ->
        Logger.warning("Could not record declined GitHub email: #{inspect(reason)}")
        finish(conn, user)
    end
  end

  defp decide(conn, user, _email, _decision), do: finish(conn, user)

  defp adopt(conn, user, email) do
    case Ash.update(user, %{email: email},
           action: :adopt_github_email,
           actor: user
         ) do
      {:ok, updated} ->
        conn
        |> put_flash(:info, "Email updated to #{email}.")
        |> finish(updated)

      {:error, reason} ->
        Logger.warning("Could not adopt GitHub email: #{inspect(reason)}")

        conn
        |> put_flash(:error, "Could not update your email address.")
        |> finish(user)
    end
  end

  defp refuse_taken(conn, user) do
    conn
    |> put_flash(:error, "That email already belongs to another Camelot account.")
    |> finish(user)
  end

  # The question has been answered either way — drop the
  # pending address so the prompt doesn't reappear, then let
  # the shared flow take the next step (usually the board,
  # or the App install page for a brand new user).
  defp finish(conn, user) do
    conn
    |> delete_session(GithubLoginFlow.pending_email_key())
    |> assign(:current_user, user)
    |> GithubLoginFlow.next_step(user)
  end
end
