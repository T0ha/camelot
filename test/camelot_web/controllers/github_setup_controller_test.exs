defmodule CamelotWeb.GithubSetupControllerTest do
  use CamelotWeb.ConnCase, async: false

  alias CamelotWeb.GithubSetupController

  setup do
    previous = Application.get_env(:camelot, :github_app)
    Application.put_env(:camelot, :github_app, [])
    on_exit(fn -> Application.put_env(:camelot, :github_app, previous) end)
    :ok
  end

  describe "GET /github/setup" do
    test "redirects with an error when installation_id is missing", ctx do
      %{conn: conn} = register_and_log_in_user(ctx)

      conn = get(conn, ~p"/github/setup")

      assert redirected_to(conn) == ~p"/profile"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Missing installation_id"
    end

    test "redirects with an error when the state token is missing", ctx do
      %{conn: conn} = register_and_log_in_user(ctx)

      conn = get(conn, ~p"/github/setup?installation_id=1")

      assert redirected_to(conn) == ~p"/profile"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Could not connect"
    end

    test "redirects with an error when the state token was signed for a different user", ctx do
      %{conn: conn} = register_and_log_in_user(ctx)

      other_user_id = Ash.UUID.generate()
      state = GithubSetupController.state_token(other_user_id)

      conn = get(conn, ~p"/github/setup?installation_id=1&state=#{state}")

      assert redirected_to(conn) == ~p"/profile"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Could not connect"
    end

    test "redirects with an error when the App isn't configured, without calling GitHub", ctx do
      %{conn: conn, user: user} = register_and_log_in_user(ctx)

      state = GithubSetupController.state_token(user.id)

      conn = get(conn, ~p"/github/setup?installation_id=1&state=#{state}")

      assert redirected_to(conn) == ~p"/profile"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Could not connect"
    end
  end
end
