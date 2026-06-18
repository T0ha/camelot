defmodule CamelotWeb.TaskLiveTest do
  use CamelotWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Camelot.Agents.Agent
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

  describe "reset_task" do
    test "re-queues task and marks agent idle", %{conn: conn, project: project, user: user} do
      {:ok, agent} =
        Ash.create(Agent, %{
          name: "stuck-agent",
          template_id: agent_template!("claude_code").id,
          project_id: project.id,
          user_id: user.id
        })

      {:ok, task} =
        Ash.create(Task, %{
          title: "Stuck task",
          project_id: project.id,
          creator_id: user.id
        })

      {:ok, task} =
        Ash.update(task, %{agent_id: agent.id}, action: :begin_work)

      {:ok, _busy} = Ash.update(agent, %{}, action: :mark_busy)

      assert task.stage == :planning
      assert task.state == :in_progress

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      html =
        view
        |> element("button", "Reset Task")
        |> render_click()

      assert html =~ "work will resume"

      {:ok, reloaded} = Ash.get(Task, task.id, load: [:agent])
      assert reloaded.state == :queued
      assert reloaded.stage == :planning
      assert reloaded.agent.status == :idle
    end

    test "button is hidden when no agent is assigned", %{conn: conn, task: task} do
      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")
      refute html =~ "Reset Task"
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
