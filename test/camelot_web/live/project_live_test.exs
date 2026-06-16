defmodule CamelotWeb.ProjectLiveTest do
  use CamelotWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Camelot.Accounts.User
  alias Camelot.Projects.Project

  setup :register_and_log_in_user

  describe "Index" do
    test "lists projects", %{conn: conn, user: user} do
      {:ok, _project} =
        Ash.create(
          Project,
          %{name: "test-project", path: "/tmp/test"},
          actor: user
        )

      {:ok, _view, html} = live(conn, ~p"/projects")
      assert html =~ "Projects"
      assert html =~ "test-project"
    end

    test "redirects unauthenticated users" do
      conn = build_conn()

      assert {:error,
              {
                :redirect,
                %{to: "/sign-in"}
              }} = live(conn, ~p"/projects")
    end
  end

  describe "Show" do
    test "displays project details", %{conn: conn, user: user} do
      {:ok, project} =
        Ash.create(
          Project,
          %{
            name: "show-project",
            path: "/tmp/show",
            description: "A test project"
          },
          actor: user
        )

      {:ok, _view, html} =
        live(conn, ~p"/projects/#{project.id}")

      assert html =~ "show-project"
      assert html =~ "A test project"
    end

    test "redirects non-member from another user's project", %{conn: conn} do
      other = Ash.Seed.seed!(User, %{email: "other-#{System.unique_integer()}@x.com"})

      {:ok, project} =
        Ash.create(Project, %{name: "private-#{System.unique_integer()}", path: "/tmp/p"}, actor: other)

      assert {:error, {kind, %{to: "/projects"}}} =
               live(conn, ~p"/projects/#{project.id}")

      assert kind in [:redirect, :live_redirect]
    end
  end

  describe "scoping" do
    test "non-admin sees only memberships", %{conn: conn, user: user} do
      {:ok, _mine} =
        Ash.create(Project, %{name: "mine-#{System.unique_integer()}", path: "/tmp/mine"}, actor: user)

      other = Ash.Seed.seed!(User, %{email: "other-#{System.unique_integer()}@x.com"})

      {:ok, _theirs} =
        Ash.create(Project, %{name: "theirs-#{System.unique_integer()}", path: "/tmp/theirs"}, actor: other)

      {:ok, _view, html} = live(conn, ~p"/projects")
      assert html =~ "mine-"
      refute html =~ "theirs-"
    end
  end

  describe "admin toggle" do
    setup :register_and_log_in_admin

    test "admin defaults to mine; can toggle to see all", %{conn: conn, user: admin} do
      other = Ash.Seed.seed!(User, %{email: "user-#{System.unique_integer()}@x.com"})

      {:ok, _mine} =
        Ash.create(Project, %{name: "admin-own-#{System.unique_integer()}", path: "/tmp/a"}, actor: admin)

      {:ok, _theirs} =
        Ash.create(Project, %{name: "user-own-#{System.unique_integer()}", path: "/tmp/b"}, actor: other)

      {:ok, view, html} = live(conn, ~p"/projects")
      assert html =~ "admin-own-"
      refute html =~ "user-own-"

      html = view |> element("button", "Showing:") |> render_click()
      assert html =~ "admin-own-"
      assert html =~ "user-own-"
    end
  end
end
