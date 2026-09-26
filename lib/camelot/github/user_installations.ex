defmodule Camelot.Github.UserInstallations do
  @moduledoc """
  Discovers which GitHub App installations the *signed-in
  user* can see, and links them to their Camelot account.

  Used by the "Log in with GitHub" callback so a first-time
  user lands on the board already connected, instead of
  being sent to `/profile` for a second, manual step.
  GitHub's `GET /user/installations` payloads already have
  the exact shape `Camelot.Github.InstallationSync.upsert/1`
  consumes, so nothing needs normalising here.

  The user access token is used only for the duration of
  the request and never persisted.
  """

  alias Camelot.Accounts.User
  alias Camelot.Github.AppConfig
  alias Camelot.Github.Installation
  alias Camelot.Github.InstallationSync
  alias Camelot.Telemetry.Capture
  alias Camelot.Telemetry.Reason

  require Logger

  @url "https://api.github.com/user/installations"

  # This runs on the login critical path, so cap the wait
  # rather than letting a slow GitHub hold the redirect.
  @receive_timeout 10_000

  @doc """
  Lists the App installations visible to the holder of
  `access_token`.
  """
  @spec list(String.t() | nil) :: {:ok, [map()]} | {:error, term()}
  def list(nil), do: {:error, :no_access_token}

  def list(access_token) do
    if AppConfig.configured?() do
      request(access_token)
    else
      {:error, :not_configured}
    end
  end

  @doc """
  Upserts each installation payload and links it to `user`.

  Individual failures — most often an installation another
  Camelot user already claimed — are logged, reported as
  `github_setup_failed` and skipped, so one bad row can't
  cost the user the rest of them.

  A link this call actually makes reports `github_setup_succeeded`,
  the same event the profile-driven setup callback captures; an
  installation that is already the user's reports nothing, since
  this runs on every GitHub login.
  """
  @spec link([map()], User.t()) :: :ok
  def link(payloads, %User{} = user) do
    Enum.each(payloads, &link_one(&1, user))
  end

  @doc """
  `list/1` followed by `link/2`.
  """
  @spec sync(String.t() | nil, User.t()) :: :ok | {:error, term()}
  def sync(access_token, %User{} = user) do
    case list(access_token) do
      {:ok, payloads} -> link(payloads, user)
      {:error, reason} -> {:error, reason}
    end
  end

  defp request(access_token) do
    [
      url: @url,
      params: [per_page: 100],
      headers: [
        {"authorization", "Bearer #{access_token}"},
        {"accept", "application/vnd.github+json"}
      ],
      receive_timeout: @receive_timeout
    ]
    |> Req.get()
    |> case do
      {:ok, %Req.Response{status: 200, body: %{"installations" => installations}}} ->
        {:ok, installations}

      {:ok, %Req.Response{status: 200, body: body}} ->
        {:error, {:unexpected_body, body}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp link_one(payload, user) do
    case upsert_and_link(payload, user) do
      {:ok, :linked} -> capture_succeeded(payload, user)
      {:ok, :already_linked} -> :ok
      {:error, reason} -> report_failure(payload, user, reason)
    end
  end

  @spec upsert_and_link(map(), User.t()) ::
          {:ok, :linked | :already_linked} | {:error, term()}
  defp upsert_and_link(payload, user) do
    with {:ok, %Installation{} = installation} <- upsert(payload) do
      link_user(installation, user)
    end
  end

  @spec upsert(map()) :: {:ok, Installation.t()} | {:error, term()}
  defp upsert(payload) do
    case InstallationSync.upsert(payload) do
      {:ok, %Installation{} = installation} -> {:ok, installation}
      {:error, reason} -> {:error, {:upsert_failed, reason}}
    end
  end

  # Re-linking an installation that is already this user's writes
  # nothing, but the Ash update still notifies — and this runs on
  # every GitHub login, so `github_installation_linked` would count
  # logins rather than links.
  @spec link_user(Installation.t(), User.t()) ::
          {:ok, :linked | :already_linked} | {:error, term()}
  defp link_user(%Installation{user_id: user_id}, %User{id: user_id}) do
    {:ok, :already_linked}
  end

  defp link_user(installation, user) do
    case Ash.update(installation, %{user_id: user.id}, action: :link_user, actor: user) do
      {:ok, %Installation{}} -> {:ok, :linked}
      {:error, reason} -> {:error, {:link_failed, reason}}
    end
  end

  # Folding the install into the login round-trip is the *intended*
  # way to connect — a first-time GitHub sign-in lands on the board
  # already connected, with no second step on /profile. Capturing the
  # same event `CamelotWeb.GithubSetupController` does is what keeps
  # the funnel's GitHub step reachable from both paths; without it
  # everyone who took this one looked like a drop-off.
  @spec capture_succeeded(map(), User.t()) :: :ok
  defp capture_succeeded(payload, user) do
    Capture.capture("github_setup_succeeded", user, %{
      installation_id: payload["id"],
      account_type: get_in(payload, ["account", "type"]),
      repository_selection: payload["repository_selection"]
    })
  end

  # Most often the installation belongs to another Camelot account,
  # which is a connect the user cannot complete — a funnel stop, not
  # an incident, hence `info`. The reason is a bounded
  # `Camelot.Telemetry.Reason` value rather than `inspect/1` output,
  # so the event stays groupable and the log line filterable.
  @spec report_failure(map(), User.t(), term()) :: :ok
  defp report_failure(payload, user, reason) do
    {classified, http_status} = Reason.classify(reason)

    Logger.info("GitHub login: skipping installation",
      user_id: user.id,
      installation_id: payload["id"],
      reason: classified,
      http_status: http_status
    )

    Capture.capture("github_setup_failed", user, %{
      reason: classified,
      http_status: http_status
    })
  end
end
