defmodule CamelotWeb.GithubLoginFlowTest do
  use CamelotWeb.ConnCase, async: false

  alias Camelot.Accounts.User
  alias Camelot.Github.Installation
  alias CamelotWeb.GithubLoginFlow

  @app_config [
    app_id: "123",
    slug: "camelot-dev",
    client_id: "Iv1.abc",
    client_secret: "secret",
    private_key: Base.encode64("-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----\n"),
    webhook_secret: "whsecret"
  ]

  setup do
    previous = Application.get_env(:camelot, :github_app)
    Application.put_env(:camelot, :github_app, @app_config)
    on_exit(fn -> Application.put_env(:camelot, :github_app, previous) end)
    :ok
  end

  defp seed_user!(attrs \\ %{}) do
    defaults = %{
      email: "flow-#{System.unique_integer([:positive])}@example.com",
      confirmed_at: DateTime.utc_now()
    }

    Ash.Seed.seed!(User, Map.merge(defaults, attrs))
  end

  defp install!(user) do
    Ash.Seed.seed!(Installation, %{
      installation_id: System.unique_integer([:positive]),
      account_login: "octocat",
      account_type: :user,
      user_id: user.id
    })
  end

  defp conn_with(session) do
    :get
    |> build_conn("/")
    |> Plug.Conn.fetch_query_params()
    |> Phoenix.ConnTest.init_test_session(session)
    |> Phoenix.Controller.fetch_flash()
  end

  describe "the email prompt takes priority" do
    test "a pending email sends the user to the prompt page" do
      user = seed_user!()
      install!(user)

      conn =
        [github_pending_email: "new@example.com"]
        |> conn_with()
        |> GithubLoginFlow.next_step(user)

      assert redirected_to(conn) == "/github/email"
    end

    test "an address the user already declined is skipped" do
      user = seed_user!(%{github_email_declined: "new@example.com"})
      install!(user)

      conn =
        [github_pending_email: "New@Example.com"]
        |> conn_with()
        |> GithubLoginFlow.next_step(user)

      assert redirected_to(conn) == "/"
    end

    test "an address owned by another Camelot user is skipped" do
      seed_user!(%{email: "taken@example.com"})
      user = seed_user!()
      install!(user)

      conn =
        [github_pending_email: "taken@example.com"]
        |> conn_with()
        |> GithubLoginFlow.next_step(user)

      assert redirected_to(conn) == "/"
    end
  end

  describe "the install prompt" do
    test "redirects a user with no installations to github.com" do
      user = seed_user!()

      conn = GithubLoginFlow.next_step(conn_with(%{}), user)

      assert redirected_to(conn) =~
               "https://github.com/apps/camelot-dev/installations/new?state="

      assert Plug.Conn.get_session(conn, :github_install_prompted)
    end

    test "does not bounce a user who was already prompted" do
      user = seed_user!()

      conn =
        [github_install_prompted: true]
        |> conn_with()
        |> GithubLoginFlow.next_step(user)

      assert redirected_to(conn) == "/"
    end

    test "goes straight to the board once an installation is linked" do
      user = seed_user!()
      install!(user)

      conn = GithubLoginFlow.next_step(conn_with(%{}), user)

      assert redirected_to(conn) == "/"
      refute Plug.Conn.get_session(conn, :github_install_prompted)
    end

    test "falls back to the board when the app isn't configured" do
      Application.put_env(:camelot, :github_app, [])
      user = seed_user!()

      conn = GithubLoginFlow.next_step(conn_with(%{}), user)

      assert redirected_to(conn) == "/"
    end
  end
end
