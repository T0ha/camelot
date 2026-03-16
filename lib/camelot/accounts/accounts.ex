defmodule Camelot.Accounts do
  @moduledoc """
  Domain for user authentication and account management.
  """
  use Ash.Domain

  resources do
    resource(Camelot.Accounts.User)
    resource(Camelot.Accounts.Token)
  end
end
