defmodule Camelot.Github.RepositoryCatalog do
  @moduledoc """
  Aggregates the GitHub repositories accessible to a user
  across all of their connected (non-suspended) GitHub App
  installations, for the project GitHub owner/repo picker.

  No caching layer here — callers (the `GithubRepoPicker`
  LiveComponent) fetch once per "open" and hold the result
  in their own assigns for the life of that popup.
  """

  alias Camelot.Github.Client
  alias Camelot.Github.Installation

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
  @spec list_for_user(Camelot.Accounts.User.t()) :: {:ok, [repo()]} | {:error, term()}
  def list_for_user(user) do
    with {:ok, user} <- Ash.load(user, :github_installations, actor: user) do
      repos =
        user.github_installations
        |> Enum.reject(&suspended?/1)
        |> Enum.map(&fetch_repos/1)
        |> merge_repos()

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

  defp fetch_repos(%Installation{installation_id: installation_id}) do
    case Client.list_installation_repositories(installation_id) do
      {:ok, repos} -> repos
      {:error, _reason} -> []
    end
  end
end
