defmodule Camelot.Agents.UsageSnapshot.Preparations.Latest do
  @moduledoc """
  Narrows `Camelot.Agents.UsageSnapshot`'s `:latest` read to the most
  recent row for one key.

  With a `credential_id` the key is that credential; without one it is
  the env-var fallback — the user's rows of that kind that were
  recorded with no credential. The two never mix: once a user stores
  a key, readings taken against the env var no longer describe the
  account the next run will use.
  """
  use Ash.Resource.Preparation

  require Ash.Query

  @impl true
  @spec prepare(Ash.Query.t(), keyword(), Ash.Resource.Preparation.Context.t()) :: Ash.Query.t()
  def prepare(query, _opts, _context) do
    query
    |> Ash.Query.filter(window == ^Ash.Query.get_argument(query, :window))
    |> filter_key(
      Ash.Query.get_argument(query, :credential_id),
      Ash.Query.get_argument(query, :user_id),
      Ash.Query.get_argument(query, :credential_kind)
    )
    |> Ash.Query.sort(observed_at: :desc)
    |> Ash.Query.limit(1)
  end

  defp filter_key(query, nil, user_id, kind) do
    Ash.Query.filter(
      query,
      is_nil(credential_id) and user_id == ^user_id and credential_kind == ^kind
    )
  end

  defp filter_key(query, credential_id, _user_id, _kind) do
    Ash.Query.filter(query, credential_id == ^credential_id)
  end
end
