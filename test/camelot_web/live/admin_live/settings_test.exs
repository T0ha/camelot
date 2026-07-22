defmodule CamelotWeb.AdminLive.SettingsTest do
  use CamelotWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias AshAuthentication.Plug.Helpers, as: AuthHelpers
  alias Camelot.Accounts.User
  alias Camelot.Settings.SystemSetting

  defp login_conn(%{conn: conn}, role) do
    email = "#{role}-#{System.unique_integer()}@example.com"
    user = Ash.Seed.seed!(User, %{email: email, role: role})

    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)
    user = %{user | __metadata__: Map.put(user.__metadata__, :token, token)}

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> AuthHelpers.store_in_session(user)

    %{conn: conn, user: user}
  end

  describe "as admin" do
    setup ctx do
      login_conn(ctx, :admin)
    end

    test "shows the current global default", %{conn: conn} do
      Ash.Seed.seed!(SystemSetting, %{default_swarm_node_label: "gpu-default"})

      {:ok, _view, html} = live(conn, ~p"/admin/settings")

      assert html =~ "gpu-default"
    end

    test "sets the global default via the form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      html =
        view
        |> form("#system-settings-form", %{"default_swarm_node_label" => "gpu-new"})
        |> render_change()

      assert html =~ "gpu-new"
      assert Camelot.Settings.default_swarm_node_label() == "gpu-new"
    end
  end

  describe "as a non-admin user" do
    setup ctx do
      login_conn(ctx, :user)
    end

    test "redirects away from /admin/settings", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin/settings")
    end
  end

  describe "as an anonymous visitor" do
    test "redirects to /sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: target}}} = live(conn, ~p"/admin/settings")
      assert target =~ "sign-in" or target == "/"
    end
  end
end
