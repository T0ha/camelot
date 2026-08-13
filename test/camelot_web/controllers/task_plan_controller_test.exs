defmodule CamelotWeb.TaskPlanControllerTest do
  use CamelotWeb.ConnCase, async: true

  alias Camelot.Board.Task
  alias Camelot.Projects.Project

  setup %{conn: conn} do
    %{conn: conn, user: user} = register_and_log_in_user(%{conn: conn})

    {:ok, project} =
      Ash.create(
        Project,
        %{name: "plan-download-proj", path: "/tmp/plan-download-proj"},
        actor: user
      )

    task =
      Ash.Seed.seed!(Task, %{
        title: "Plan task",
        project_id: project.id,
        creator_id: user.id,
        plan: "See ~/.claude/plans/x.md — summary here.",
        full_plan: "# Full plan\n\nStep 1\nStep 2"
      })

    %{conn: conn, user: user, project: project, task: task}
  end

  describe "GET /tasks/:id/plan/download" do
    test "sends full_plan as a markdown attachment", %{conn: conn, task: task} do
      conn = get(conn, ~p"/tasks/#{task.id}/plan/download")

      assert response(conn, 200) == "# Full plan\n\nStep 1\nStep 2"
      assert response_content_type(conn, :markdown) =~ "text/markdown"

      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment"
      assert disposition =~ "task-#{task.id}-plan.md"
    end

    test "falls back to plan when full_plan is absent", %{
      conn: conn,
      user: user,
      project: project
    } do
      task =
        Ash.Seed.seed!(Task, %{
          title: "Summary-only task",
          project_id: project.id,
          creator_id: user.id,
          plan: "Inline plan only"
        })

      conn = get(conn, ~p"/tasks/#{task.id}/plan/download")

      assert response(conn, 200) == "Inline plan only"
    end

    test "404 when the task has no plan at all", %{
      conn: conn,
      user: user,
      project: project
    } do
      task =
        Ash.Seed.seed!(Task, %{
          title: "Planless task",
          project_id: project.id,
          creator_id: user.id
        })

      conn = get(conn, ~p"/tasks/#{task.id}/plan/download")

      assert conn.status == 404
    end

    test "404 for a user who isn't a member of the task's project", %{task: task} do
      conn = Phoenix.ConnTest.build_conn()
      %{conn: conn} = register_and_log_in_user(%{conn: conn})

      conn = get(conn, ~p"/tasks/#{task.id}/plan/download")

      assert conn.status == 404
    end

    test "404 for an anonymous request", %{task: task} do
      conn = Phoenix.ConnTest.build_conn()

      conn = get(conn, ~p"/tasks/#{task.id}/plan/download")

      assert conn.status == 404
    end

    test "an admin can download any task's plan", %{task: task} do
      conn = Phoenix.ConnTest.build_conn()
      %{conn: conn} = register_and_log_in_admin(%{conn: conn})

      conn = get(conn, ~p"/tasks/#{task.id}/plan/download")

      assert response(conn, 200) == "# Full plan\n\nStep 1\nStep 2"
    end
  end
end
