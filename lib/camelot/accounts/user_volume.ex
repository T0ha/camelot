defmodule Camelot.Accounts.UserVolume do
  @moduledoc """
  Naming helpers for the per-user Docker volume that
  caches each user's agent profile state.

  The volume is a *cache*, not a source of truth: losing
  it is recoverable because credentials and configured
  MCPs live in the DB and are re-materialized by the
  runner image's entrypoint on next spawn.
  """

  alias Camelot.Accounts.User

  @doc """
  Returns the stable Docker volume name for the given
  user. The same id always yields the same name so
  Reconciler and SecretSync can find the volume across
  Camelot restarts.
  """
  @spec name(User.t() | Ash.UUID.t()) :: String.t()
  def name(%User{id: id}), do: name(id)
  def name(id) when is_binary(id), do: "camelot_user_#{id}_profile"
end
