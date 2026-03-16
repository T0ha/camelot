defmodule Camelot.Repo do
  use AshPostgres.Repo, otp_app: :camelot

  @doc """
  PostgreSQL extensions required by Ash.
  """
  @spec installed_extensions() :: [String.t()]
  def installed_extensions do
    ["ash-functions", "uuid-ossp", "citext"]
  end

  @doc """
  Minimum supported PostgreSQL version.
  """
  @spec min_pg_version() :: Version.t()
  def min_pg_version do
    %Version{major: 16, minor: 0, patch: 0}
  end
end
