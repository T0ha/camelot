defmodule CamelotWeb.TaskLiveTest do
  use CamelotWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Camelot.Board.Task
  alias Camelot.Projects.Project

  setup :register_and_log_in_user

  setup %{user: user} do
    {:ok, project} =
      Ash.create(
        Project,
        %{name: "task-live-proj", path: "/tmp/task-live-proj"},
        actor: user
      )

    {:ok, task} =
      Ash.create(Task, %{
        title: "Live task",
        description: "A task for live testing",
        project_id: project.id,
        creator_id: user.id
      })

    %{task: task, project: project}
  end

  describe "mount" do
    test "renders task detail", %{conn: conn, task: task} do
      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")
      assert html =~ "Live task"
      assert html =~ "todo"
    end
  end

  describe "cancel" do
    test "cancels a task", %{conn: conn, task: task} do
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert view
             |> element("button", "Cancel")
             |> render_click() =~ "cancelled"
    end
  end

  describe "scoping" do
    test "redirects non-member from another user's task", %{conn: conn} do
      other = Ash.Seed.seed!(Camelot.Accounts.User, %{email: "to-#{System.unique_integer()}@x.com"})

      {:ok, project} =
        Ash.create(
          Project,
          %{name: "scope-task-#{System.unique_integer()}", path: "/tmp/st"},
          actor: other
        )

      {:ok, other_task} =
        Ash.create(Task, %{
          title: "Other's task",
          project_id: project.id,
          creator_id: other.id
        })

      assert {:error, {kind, %{to: "/"}}} =
               live(conn, ~p"/tasks/#{other_task.id}")

      assert kind in [:redirect, :live_redirect]
    end
  end
end
