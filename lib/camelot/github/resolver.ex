defmodule Camelot.Github.Resolver do
  @moduledoc """
  Picks which of a user's connected GitHub App installations applies
  to a given project's GitHub org/owner.
  """

  alias Camelot.Github.Installation

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
