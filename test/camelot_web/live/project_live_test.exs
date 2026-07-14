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

  describe "runner image override" do
    test "sets the override via the edit form and shows it on the show page", %{
      conn: conn,
      user: user
    } do
      {:ok, project} =
        Ash.create(
          Project,
          %{name: "runner-image-#{System.unique_integer()}", path: "/tmp/runner"},
          actor: user
        )

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/edit")

      view
      |> form("#project-form", %{
        "name" => project.name,
        "runner_image_override" => "ghcr.io/t0ha/camelot-runner-elixir:1.19"
      })
      |> render_submit()

      {:ok, _view, html} = live(conn, ~p"/projects/#{project.id}")

      assert html =~ "ghcr.io/t0ha/camelot-runner-elixir:1.19"
    end
  end

  describe "environment variables" do
    setup %{user: user} do
      {:ok, project} =
        Ash.create(Project, %{name: "env-#{System.unique_integer()}", path: "/tmp/env"}, actor: user)

      %{project: project}
    end

    test "adds a plain env var and lists its value", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}")

      html =
        view
        |> form("#env-var-form-project-env-vars", %{
          "key" => "DATABASE_URL",
          "value" => "postgres://demo",
          "secret" => "false"
        })
        |> render_submit()

      assert html =~ "DATABASE_URL"
      assert html =~ "postgres://demo"
    end

    test "masks a secret env var's value", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}")

      html =
        view
        |> form("#env-var-form-project-env-vars", %{
          "key" => "NATS_URL",
          "value" => "nats://user:pw@host",
          "secret" => "true"
        })
        |> render_submit()

      assert html =~ "NATS_URL"
      refute html =~ "nats://user:pw@host"
      assert html =~ "••••"
    end

    test "deletes an env var", %{conn: conn, project: project} do
      {:ok, _} =
        Ash.create(Camelot.Projects.EnvVar, %{
          key: "GONE",
          value: "x",
          project_id: project.id
        })

      {:ok, view, html} = live(conn, ~p"/projects/#{project.id}")
      assert html =~ "GONE"

      html =
        view
        |> element(~s(button[phx-click="delete_env_var"]))
        |> render_click()

      refute html =~ "GONE"
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
