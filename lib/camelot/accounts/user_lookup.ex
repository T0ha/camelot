defmodule Camelot.Accounts.UserLookup do
  @moduledoc """
  Unauthenticated point lookups of `Camelot.Accounts.User`
  rows, shared by the sign-in gates and the GitHub login
  flow.

  Kept apart from the resource module so the Ash DSL and
  plain functions don't live side by side. Every read runs
  with `authorize?: false` on purpose: these are pre-actor
  lookups used to decide whether a sign-in may proceed at
  all.
  """

  alias Camelot.Accounts.User

  require Ash.Query

  @doc """
  Finds a user by email. The column is `citext`, so the
  match is case-insensitive.
  """
  @spec fetch_by_email(String.t() | Ash.CiString.t() | nil) ::
          {:ok, User.t()} | :not_found
  def fetch_by_email(nil), do: :not_found

  def fetch_by_email(email) do
    case String.trim(to_string(email)) do
      "" -> :not_found
      trimmed -> read_one(Ash.Query.filter(User, email == ^trimmed))
    end
  end

  @doc """
  Finds a user by the GitHub numeric user id stored at their
  first GitHub sign-in. A `nil` id never matches, even though
  the column is nullable.
  """
  @spec fetch_by_github_user_id(String.t() | nil) ::
          {:ok, User.t()} | :not_found
  def fetch_by_github_user_id(nil), do: :not_found

  def fetch_by_github_user_id(github_user_id) do
    read_one(Ash.Query.filter(User, github_user_id == ^github_user_id))
  end

  defp read_one(query) do
    case Ash.read_one(query, authorize?: false) do
      {:ok, %User{} = user} -> {:ok, user}
      _ -> :not_found
    end
  end
end
