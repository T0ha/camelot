defmodule Camelot.Accounts.Token do
  @moduledoc """
  Token resource for authentication tokens.
  """
  use Ash.Resource,
    domain: Camelot.Accounts,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAuthentication.TokenResource],
    authorizers: []

  postgres do
    table("tokens")
    repo(Camelot.Repo)
  end

  actions do
    defaults([:read, :destroy])
  end
end
