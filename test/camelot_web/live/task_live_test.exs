defmodule CamelotWeb.TaskLiveTest do
  use CamelotWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Camelot.Board.Task
  alias Camelot.Projects.Project

  setup :register_and_log_in_user

  setup %{user: user} do
    {:ok, project} =
      Ash.create(Project, %{
        name: "task-live-proj",
        path: "/tmp/task-live-proj"
      })

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
      assert html =~ "created"
    end
  end

  describe "transitions" do
    test "start_planning transitions task",
         %{conn: conn, task: task} do
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert view
             |> element(
               "button",
               "Start Planning"
             )
             |> render_click() =~ "planning"
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
end
