defmodule CamelotWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use CamelotWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  alias AshAuthentication.Plug.Helpers, as: AuthHelpers
  alias Camelot.Accounts.User

  using do
    quote do
      use CamelotWeb, :verified_routes

      import CamelotWeb.ConnCase
      import Phoenix.ConnTest
      import Plug.Conn
      # The default endpoint for testing
      @endpoint CamelotWeb.Endpoint

      # Import conveniences for testing with connections
    end
  end

  setup tags do
    Camelot.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Registers a user and stores them in the connection
  session for authenticated test requests.
  """
  @spec register_and_log_in_user(%{conn: Plug.Conn.t()}) ::
          %{conn: Plug.Conn.t(), user: Ash.Resource.record()}
  def register_and_log_in_user(%{conn: conn}) do
    email = "test-#{System.unique_integer()}@example.com"

    user = Ash.Seed.seed!(User, %{email: email})

    {:ok, token, _claims} =
      AshAuthentication.Jwt.token_for_user(user)

    user = %{user | __metadata__: Map.put(user.__metadata__, :token, token)}

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> AuthHelpers.store_in_session(user)

    %{conn: conn, user: user}
  end
end
