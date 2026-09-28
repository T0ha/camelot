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
  alias Camelot.Telemetry.Capture
  alias Camelot.Telemetry.Reason

  require Logger

  @state_salt "github_setup_state"
  @state_max_age_s 600

  @spec new(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def new(conn, %{"installation_id" => installation_id_str} = params) do
    with {:ok, user} <- verify_state(params["state"], conn.assigns[:current_user]),
         {:ok, installation_id} <- parse_integer(installation_id_str),
         {:ok, gh_installation} <- fetch_installation(installation_id),
         {:ok, installation} <- upsert_installation(gh_installation),
         {:ok, _installation} <- link_user(installation, user) do
      capture_succeeded(user, installation_id, gh_installation)

      conn
      |> put_flash(:info, "GitHub App connected.")
      |> redirect(to: ~p"/profile")
    else
      {:error, reason} ->
        report_failure(conn.assigns[:current_user], reason)

        conn
        |> put_flash(:error, "Could not connect the GitHub App.")
        |> redirect(to: ~p"/profile")
    end
  end

  # GitHub comes back here with no installation_id when the install
  # never happened — an org owner has to approve it first, or the user
  # backed out of the install screen. That is a funnel stop of its own,
  # and reporting it as `invalid_installation_id` would blame a parse
  # that was never attempted.
  def new(conn, _params) do
    report_failure(conn.assigns[:current_user], :missing_installation_id)

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

  defp upsert_installation(gh_installation) do
    case InstallationSync.upsert(gh_installation) do
      {:ok, installation} -> {:ok, installation}
      {:error, reason} -> {:error, {:upsert_failed, reason}}
    end
  end

  defp link_user(installation, user) do
    case Ash.update(installation, %{user_id: user.id}, action: :link_user, actor: user) do
      {:ok, installation} -> {:ok, installation}
      {:error, reason} -> {:error, {:link_failed, reason}}
    end
  end

  # `repository_selection` is the difference between an App that can
  # see every repository and one the user pointed at a single repo —
  # the second is a common way to end up with a project Camelot
  # cannot actually clone.
  @spec capture_succeeded(User.t(), integer(), map()) :: :ok
  defp capture_succeeded(user, installation_id, gh_installation) do
    Capture.capture("github_setup_succeeded", user, %{
      installation_id: installation_id,
      account_type: get_in(gh_installation, ["account", "type"]),
      repository_selection: gh_installation["repository_selection"]
    })
  end

  # One event per distinct error shape, never `inspect(reason)`: the
  # point is a `reason` a funnel drop-off can be grouped by. The log
  # line carries the same bounded value as metadata, so the JSON log
  # pipeline can filter on exactly what the event reports.
  @spec report_failure(User.t() | nil, term()) :: :ok
  defp report_failure(user, reason) do
    {classified, http_status} = Reason.classify(reason)

    Logger.warning("GitHub setup callback failed",
      reason: classified,
      http_status: http_status,
      user_id: user_id(user)
    )

    Capture.capture("github_setup_failed", user, %{
      reason: classified,
      http_status: http_status
    })
  end

  defp user_id(%User{id: id}), do: id
  defp user_id(_no_user), do: nil
end
