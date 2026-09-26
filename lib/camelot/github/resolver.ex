defmodule Camelot.Github.Resolver do
  @moduledoc """
  Picks which of a user's connected GitHub App installations applies
  to a given project's GitHub org/owner.
  """

  alias Camelot.Github.Installation

  @typedoc """
  Why a repository owner is not covered. Both are members of
  `t:Camelot.Telemetry.Reason.reason/0`, so they report unchanged.
  """
  @type unresolved :: :no_installation | :repo_not_in_installation

  @typedoc "Result of `owner_coverage/2`."
  @type coverage :: :ok | {:error, unresolved()}

  @doc """
  Resolves the installation id matching `github_owner`
  case-insensitively against `account_login`. Falls back to the sole
  installation when there is exactly one and no login match. Returns
  `nil` when nothing matches and more than one installation exists.
  """
  @spec installation_id([Installation.t()], String.t() | nil) :: integer() | nil
  def installation_id(installations, github_owner) do
    case {matching_by_login(installations, github_owner), installations} do
      {%Installation{installation_id: id}, _} -> id
      {nil, [%Installation{installation_id: id}]} -> id
      {nil, _} -> nil
    end
  end

  @doc """
  Whether `github_owner` is one of the accounts `installations` cover,
  as a bounded `Camelot.Telemetry.Reason` value.

  Deliberately *not* `installation_id/2`: that falls back to the sole
  installation when no login matches, which hands the runner a token
  minted for an account that does not contain the repository. The
  clone then fails with `Authentication failed` and nothing has said
  why. Coverage has no fallback — it answers whether the owner itself
  was ever installed, which is the question a funnel drop-off needs.

  A project with no `github_owner` has nothing to resolve.
  """
  @spec owner_coverage([Installation.t()], String.t() | nil) :: coverage()
  def owner_coverage(_installations, nil), do: :ok
  def owner_coverage([], _github_owner), do: {:error, :no_installation}

  def owner_coverage(installations, github_owner) do
    case matching_by_login(installations, github_owner) do
      %Installation{} -> :ok
      nil -> {:error, :repo_not_in_installation}
    end
  end

  defp matching_by_login(_installations, nil), do: nil

  defp matching_by_login(installations, github_owner) do
    Enum.find(installations, fn installation ->
      String.downcase(installation.account_login) == String.downcase(github_owner)
    end)
  end

  @doc """
  True when two projects share a GitHub repo — `github_owner` and
  `github_repo` both set and equal.

  Shared by `Camelot.Board.PromptBuilder` (same-repo blockers get a
  stacked-branch directive) and `Camelot.Board.Changes.CheckPrStatus`
  (same-repo blockers get rebase notices) so the two checks can't
  drift apart. Cross-repo links still gate dispatch and inject
  context, but there is no git branch to share across repositories.
  """
  @spec same_repo?(map(), map()) :: boolean()
  def same_repo?(%{github_owner: owner, github_repo: repo}, %{github_owner: owner, github_repo: repo})
      when not is_nil(owner) and not is_nil(repo) do
    true
  end

  def same_repo?(_project_a, _project_b), do: false
end
