defmodule CamelotWeb.AdminLive.UsersTest do
  use CamelotWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias AshAuthentication.Plug.Helpers, as: AuthHelpers
  alias Camelot.Accounts.User

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

    test "lists users", %{conn: conn, user: admin} do
      Ash.Seed.seed!(User, %{email: "listed@example.com", role: :user})

      {:ok, _view, html} = live(conn, ~p"/admin/users")

      assert html =~ "Users"
      assert html =~ to_string(admin.email)
      assert html =~ "listed@example.com"
    end

    test "adds a user via the form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/users")

      added_email = "added-#{System.unique_integer()}@example.com"

      html =
        view
        |> form("form[phx-submit=create_user]", %{
          "user" => %{"email" => added_email, "role" => "user"}
        })
        |> render_submit()

      assert html =~ added_email
      assert html =~ "Added user #{added_email}"
    end

    test "promotes another user via the per-row select", %{conn: conn} do
      target = Ash.Seed.seed!(User, %{email: "promote-me@example.com", role: :user})

      {:ok, view, _html} = live(conn, ~p"/admin/users")

      html =
        view
        |> form("#user-#{target.id} form[phx-change=set_role]", %{
          "user" => %{"id" => target.id, "role" => "admin"}
        })
        |> render_change()

      assert html =~ "promote-me@example.com is now admin"
    end

    test "pins another user's runners to a swarm node", %{conn: conn} do
      target = Ash.Seed.seed!(User, %{email: "pin-target-#{System.unique_integer()}@example.com"})

      {:ok, view, _html} = live(conn, ~p"/admin/users")

      html =
        view
        |> form("#user-#{target.id} form[phx-change=set_node_label]", %{
          "node" => %{"id" => target.id, "swarm_node_label" => "gpu-9"}
        })
        |> render_change()

      assert html =~ "gpu-9"
      assert Ash.get!(User, target.id, authorize?: false).swarm_node_label == "gpu-9"
    end

    test "cannot change own role", %{conn: conn, user: admin} do
      {:ok, view, _html} = live(conn, ~p"/admin/users")

      # the admin's own row has no role-select form (the node pin
      # form is still present — admins may pin their own runners)
      assert has_element?(view, "#user-#{admin.id}")
      refute has_element?(view, "#user-#{admin.id} form[phx-change=set_role]")
    end
  end

  describe "as a non-admin user" do
    setup ctx do
      login_conn(ctx, :user)
    end

    test "redirects away from /admin/users", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin/users")
    end
  end

  describe "as an anonymous visitor" do
    test "redirects to /sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: target}}} = live(conn, ~p"/admin/users")
      assert target =~ "sign-in" or target == "/"
    end
  end
end
