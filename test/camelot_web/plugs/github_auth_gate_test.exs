defmodule CamelotWeb.Plugs.GithubAuthGateTest do
  use CamelotWeb.ConnCase, async: false

  alias CamelotWeb.Plugs.GithubAuthGate

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
    on_exit(fn -> Application.put_env(:camelot, :github_app, previous) end)
    :ok
  end

  defp conn_for(path) do
    :get
    |> build_conn(path)
    |> Plug.Conn.fetch_query_params()
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Phoenix.Controller.fetch_flash()
  end

  describe "when the GitHub App is configured" do
    setup do
      Application.put_env(:camelot, :github_app, @app_config)
      :ok
    end

    test "lets the request phase through" do
      refute GithubAuthGate.call(conn_for("/auth/user/github"), []).halted
    end

    test "lets the callback through" do
      refute GithubAuthGate.call(conn_for("/auth/user/github/callback"), []).halted
    end
  end

  describe "when the GitHub App is not configured" do
    setup do
      Application.put_env(:camelot, :github_app, [])
      :ok
    end

    test "halts the request phase with a flash + redirect" do
      conn = GithubAuthGate.call(conn_for("/auth/user/github"), [])

      assert conn.halted
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "isn't configured"
      assert redirected_to(conn) == "/sign-in"
    end

    test "halts the callback too" do
      assert GithubAuthGate.call(conn_for("/auth/user/github/callback"), []).halted
    end

    test "is a no-op for the magic-link routes" do
      conn = conn_for("/auth/user/magic_link/request")

      assert GithubAuthGate.call(conn, []) == conn
    end

    test "is a no-op for unrelated paths" do
      conn = conn_for("/")

      assert GithubAuthGate.call(conn, []) == conn
    end
  end
end
