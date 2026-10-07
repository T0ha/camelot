defmodule CamelotWeb.ProjectLiveCloudRunnerTest do
  # Mutates the global :runner app env, so it can't run async.
  use CamelotWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Camelot.Runtime.Runner.DockerEngine
  alias Camelot.Runtime.Runner.LocalPort

  setup :register_and_log_in_user

  setup do
    original = Application.get_env(:camelot, :runner)
    on_exit(fn -> Application.put_env(:camelot, :runner, original) end)
    :ok
  end

  defp put_backend(backend) do
    runner = Application.get_env(:camelot, :runner, [])
    Application.put_env(:camelot, :runner, Keyword.put(runner, :backend, backend))
  end

  describe "new project form under a cloud runner backend (DockerEngine)" do
    test "hides the path picker", %{conn: conn} do
      put_backend(DockerEngine)

      {:ok, _view, html} = live(conn, ~p"/projects/new")

      refute html =~ ~s(id="path-picker")
    end

    test "hides the Path table column", %{conn: conn} do
      put_backend(DockerEngine)

      {:ok, _view, html} = live(conn, ~p"/projects/new")

      refute html =~ "Path"
    end

    test "marks the GitHub repository field as required", %{conn: conn} do
      put_backend(DockerEngine)

      {:ok, _view, html} = live(conn, ~p"/projects/new")

      assert html =~ "GitHub Repository (required)"
    end

    test "submitting without a GitHub repo re-renders the form with a validation error", %{conn: conn} do
      put_backend(DockerEngine)

      {:ok, view, _html} = live(conn, ~p"/projects/new")

      html =
        view
        |> form("#project-form", %{"project" => %{"name" => "cloud-form-#{System.unique_integer()}"}})
        |> render_submit()

      assert html =~ "is required when the runner backend clones from a hosted repo"
    end
  end

  describe "new project form under the LocalPort runner backend" do
    test "still shows the path picker", %{conn: conn} do
      put_backend(LocalPort)

      {:ok, _view, html} = live(conn, ~p"/projects/new")

      assert html =~ ~s(id="path-picker")
    end

    test "still shows the Path table column", %{conn: conn} do
      put_backend(LocalPort)

      {:ok, _view, html} = live(conn, ~p"/projects/new")

      assert html =~ ">Path<"
    end
  end
end
