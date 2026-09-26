defmodule Camelot.Github.RepositoryCatalog do
  @moduledoc """
  Aggregates the GitHub repositories accessible to a user
  across all of their connected (non-suspended) GitHub App
  installations, for the project GitHub owner/repo picker.

  No caching layer here — callers (the `GithubRepoPicker`
  LiveComponent) fetch once per "open" and hold the result
  in their own assigns for the life of that popup.
  """

  alias Camelot.Accounts.User
  alias Camelot.Github.Client
  alias Camelot.Github.Installation
  alias Camelot.Telemetry.Capture
  alias Camelot.Telemetry.Reason

  require Logger

  @type repo :: %{
          owner: String.t(),
          repo: String.t(),
          full_name: String.t(),
          html_url: String.t()
        }

  @doc """
  Loads `user.github_installations`, drops suspended ones,
  fetches each installation's repositories, then merges,
  dedupes, and sorts the result by `full_name`.

  An installation whose API call errors is silently
  dropped rather than failing the whole listing — one
  bad/expired installation shouldn't block the picker from
  showing repos from the others.
  """
  @spec list_for_user(User.t()) :: {:ok, [repo()]} | {:error, term()}
  def list_for_user(user) do
    with {:ok, user} <- Ash.load(user, :github_installations, actor: user) do
      live = Enum.reject(user.github_installations, &suspended?/1)

      repos =
        live
        |> Enum.map(&fetch_repos(&1, user))
        |> merge_repos()

      report_empty(live, repos, user)

      {:ok, repos}
    end
  end

  @doc """
  Merges a list of repo lists into one, deduped and sorted
  by `full_name`.
  """
  @spec merge_repos([[repo()]]) :: [repo()]
  def merge_repos(repo_lists) do
    repo_lists
    |> List.flatten()
    |> Enum.uniq_by(& &1.full_name)
    |> Enum.sort_by(& &1.full_name)
  end

  defp suspended?(%Installation{suspended_at: suspended_at}), do: not is_nil(suspended_at)

  # Dropping a failing installation keeps the picker useful, but it
  # also used to make the failure invisible: a user staring at an
  # empty repository list produced no signal at all. The listing still
  # degrades silently for the user; it no longer does so for us.
  defp fetch_repos(%Installation{installation_id: installation_id}, user) do
    case Client.list_installation_repositories(installation_id) do
      {:ok, repos} ->
        repos

      {:error, reason} ->
        capture_resolve_failed(user, reason, installation_id)
        []
    end
  end

  @spec capture_resolve_failed(User.t(), term(), integer() | nil) :: :ok
  defp capture_resolve_failed(user, reason, installation_id) do
    {classified, http_status} = Reason.classify(reason)

    log_resolve_failed(classified, http_status, user, installation_id)

    Capture.capture("project_repo_resolve_failed", user, %{
      reason: classified,
      http_status: http_status
    })
  end

  # Not having connected an installation yet is the ordinary state of
  # a user who hasn't reached that step, not a fault. It is worth an
  # event — it is exactly where the funnel stalls — but logging it as
  # a failure would raise a warning on the commonest path through the
  # picker, which is how warnings stop being read.
  @spec log_resolve_failed(Reason.reason(), non_neg_integer() | nil, User.t(), integer() | nil) ::
          :ok
  defp log_resolve_failed(:no_installation, _http_status, user, _installation_id) do
    Logger.info("GitHub repository listing skipped: no installation", user_id: user.id)
  end

  defp log_resolve_failed(reason, http_status, user, installation_id) do
    Logger.warning("GitHub repository listing failed",
      user_id: user.id,
      installation_id: installation_id,
      reason: reason,
      http_status: http_status
    )
  end

  # No installation at all is the commonest way to reach an empty
  # picker, and the one the onboarding funnel most needs to see.
  defp report_empty([], _repos, user) do
    capture_resolve_failed(user, :no_installation, nil)
  end

  defp report_empty(_installations, _repos, _user), do: :ok
end
