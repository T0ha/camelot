defmodule CamelotWeb.ProjectLiveTest do
  use CamelotWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Camelot.Projects.Project

  setup :register_and_log_in_user

  describe "Index" do
    test "lists projects", %{conn: conn} do
      {:ok, _project} =
        Ash.create(Project, %{
          name: "test-project",
          path: "/tmp/test"
        })

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
    test "displays project details", %{conn: conn} do
      {:ok, project} =
        Ash.create(Project, %{
          name: "show-project",
          path: "/tmp/show",
          description: "A test project"
        })

      {:ok, _view, html} =
        live(conn, ~p"/projects/#{project.id}")

      assert html =~ "show-project"
      assert html =~ "A test project"
    end
  end
end
