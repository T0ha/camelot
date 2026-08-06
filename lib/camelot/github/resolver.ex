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
end
