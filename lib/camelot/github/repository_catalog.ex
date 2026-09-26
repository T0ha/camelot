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

  @typedoc """
  One picker row. Defined by `Camelot.Github.Client`, which is what
  builds them, so the two cannot drift — `visibility` in particular
  is read back out in `CamelotWeb.ProjectLive.Index`.
  """
  @type repo :: Client.repository()

  # One installation's listing. A failure is `:reported` rather than
  # its cause because `fetch_repos/2` has already captured it — all
  # the caller still needs to know is whether the empty list it left
  # behind should also count as an empty grant.
  @typep outcome :: {:ok, [repo()]} | {:error, :reported}

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
      outcomes =
        user.github_installations
        |> Enum.reject(&suspended?/1)
        |> Enum.map(&fetch_repos(&1, user))

      repos = outcomes |> Enum.map(&listed/1) |> merge_repos()

      report_empty(outcomes, repos, user)

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
  @spec fetch_repos(Installation.t(), User.t()) :: outcome()
  defp fetch_repos(%Installation{installation_id: installation_id}, user) do
    case Client.list_installation_repositories(installation_id) do
      {:ok, repos} ->
        {:ok, repos}

      {:error, reason} ->
        capture_resolve_failed(user, reason, installation_id)

        {:error, :reported}
    end
  end

  @spec listed(outcome()) :: [repo()]
  defp listed({:ok, repos}), do: repos
  defp listed({:error, :reported}), do: []

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

  # Nothing went wrong here either: the App is installed and holds no
  # repository the user can pick. Same reasoning, same level.
  defp log_resolve_failed(:no_repositories, _http_status, user, _installation_id) do
    Logger.info("GitHub repository listing granted no repositories", user_id: user.id)
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
  @spec report_empty([outcome()], [repo()], User.t()) :: :ok
  defp report_empty([], _repos, user) do
    capture_resolve_failed(user, :no_installation, nil)
  end

  # The quietest way to reach it is not a failure at all: every
  # installation answered, none of them with a repository the App was
  # granted. Nothing errored, so `fetch_repos/2` reported nothing, and
  # the user is left on `#github_repo_url` — where PostHog's dead
  # clicks pile up — with no signal behind them.
  defp report_empty(outcomes, [], user) do
    outcomes
    |> Enum.find(&match?({:error, _reason}, &1))
    |> report_no_repositories(user)
  end

  defp report_empty(_outcomes, _repos, _user), do: :ok

  # A listing that failed already reported its own bounded reason.
  # Counting the empty list it left behind as an empty grant as well
  # would report one picker open twice, under two different causes.
  @spec report_no_repositories(outcome() | nil, User.t()) :: :ok
  defp report_no_repositories(nil, user) do
    capture_resolve_failed(user, :no_repositories, nil)
  end

  defp report_no_repositories(_failure, _user), do: :ok
end
