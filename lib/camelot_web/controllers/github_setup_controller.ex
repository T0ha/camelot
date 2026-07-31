defmodule CamelotWeb.GithubSetupController do
  @moduledoc """
  Handles the browser redirect GitHub sends back after a
  user installs the GitHub App from their profile's
  "Connect GitHub App" link.

  The link embeds an opaque, short-lived `Phoenix.Token`
  (`state` query param) encoding the user who initiated
  the connection, so this callback can independently
  re-verify the actor before linking — GitHub's
  `installation_id` query param alone proves nothing about
  who's allowed to link it.
  """
  use CamelotWeb, :controller

  alias Camelot.Accounts.User
  alias Camelot.Github.AppConfig
  alias Camelot.Github.InstallationSync
  alias Camelot.Github.Jwt

  require Logger

  @state_salt "github_setup_state"
  @state_max_age_s 600

  @spec new(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def new(conn, %{"installation_id" => installation_id_str} = params) do
    with {:ok, user} <- verify_state(params["state"], conn.assigns[:current_user]),
         {:ok, installation_id} <- parse_integer(installation_id_str),
         {:ok, gh_installation} <- fetch_installation(installation_id),
         {:ok, installation} <- InstallationSync.upsert(gh_installation),
         {:ok, _installation} <- link_user(installation, user) do
      conn
      |> put_flash(:info, "GitHub App connected.")
      |> redirect(to: ~p"/profile")
    else
      {:error, reason} ->
        Logger.warning("GitHub setup callback failed: #{inspect(reason)}")

        conn
        |> put_flash(:error, "Could not connect the GitHub App.")
        |> redirect(to: ~p"/profile")
    end
  end

  def new(conn, _params) do
    conn
    |> put_flash(:error, "Missing installation_id from GitHub.")
    |> redirect(to: ~p"/profile")
  end

  @doc """
  Opaque, short-lived state token embedding the user a
  "Connect GitHub App" link is for. Verified in `new/2` —
  both the signature and that the actor matches the
  embedded user.
  """
  @spec state_token(String.t()) :: String.t()
  def state_token(user_id) do
    Phoenix.Token.sign(CamelotWeb.Endpoint, @state_salt, %{user_id: user_id})
  end

  defp verify_state(nil, _user), do: {:error, :missing_state}
  defp verify_state(_state, nil), do: {:error, :not_authenticated}

  defp verify_state(state, %User{} = user) do
    case Phoenix.Token.verify(CamelotWeb.Endpoint, @state_salt, state, max_age: @state_max_age_s) do
      {:ok, %{user_id: user_id}} ->
        if user_id == user.id, do: {:ok, user}, else: {:error, :actor_mismatch}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_integer(str) do
    case Integer.parse(str) do
      {int, ""} -> {:ok, int}
      _ -> {:error, :invalid_installation_id}
    end
  end

  defp fetch_installation(installation_id) do
    with true <- AppConfig.configured?(),
         {:ok, jwt} <- Jwt.signed_jwt(),
         {:ok, %Req.Response{status: 200, body: body}} <-
           Req.get(
             url: "https://api.github.com/app/installations/#{installation_id}",
             headers: [
               {"authorization", "Bearer #{jwt}"},
               {"accept", "application/vnd.github+json"}
             ]
           ) do
      {:ok, body}
    else
      false -> {:error, :not_configured}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp link_user(installation, user) do
    Ash.update(installation, %{user_id: user.id}, action: :link_user, actor: user)
  end
end
