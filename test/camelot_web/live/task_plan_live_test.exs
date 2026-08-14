defmodule CamelotWeb.TaskPlanLiveTest do
  use CamelotWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Camelot.Board.Task
  alias Camelot.Projects.Project

  setup :register_and_log_in_user

  setup %{user: user} do
    {:ok, project} =
      Ash.create(
        Project,
        %{name: "plan-live-proj", path: "/tmp/plan-live-proj"},
        actor: user
      )

    task =
      Ash.Seed.seed!(Task, %{
        title: "Plan live task",
        project_id: project.id,
        creator_id: user.id,
        plan: "See ~/.claude/plans/x.md — summary here.",
        full_plan: "# Full plan\n\n| A | B |\n|---|---|\n| 1 | 2 |"
      })

    %{task: task, project: project}
  end

  describe "mount" do
    test "renders the full plan as markdown", %{conn: conn, task: task} do
      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}/plan")

      assert html =~ "Plan live task"
      assert html =~ "<table>"
      assert html =~ "<th>A</th>"
      refute html =~ "summary here"
    end

    test "falls back to plan when full_plan is absent", %{
      conn: conn,
      project: project,
      user: user
    } do
      task =
        Ash.Seed.seed!(Task, %{
          title: "Summary-only task",
          project_id: project.id,
          creator_id: user.id,
          plan: "Inline plan only"
        })

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}/plan")

      assert html =~ "Inline plan only"
    end

    test "links back to the task and to the download", %{conn: conn, task: task} do
      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}/plan")

      assert html =~ ~p"/tasks/#{task.id}"
      assert html =~ ~p"/tasks/#{task.id}/plan/download"
    end

    test "redirects a user who isn't a member of the task's project", %{task: task} do
      conn = Phoenix.ConnTest.build_conn()
      %{conn: conn} = register_and_log_in_user(%{conn: conn})

      assert {:error, {:live_redirect, %{to: "/"}}} =
               live(conn, ~p"/tasks/#{task.id}/plan")
    end
  end
end
