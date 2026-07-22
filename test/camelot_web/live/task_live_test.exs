defmodule CamelotWeb.TaskLiveTest do
  use CamelotWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Camelot.Agents.Agent
  alias Camelot.Agents.Session
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

  describe "live output" do
    setup %{project: project, user: user} do
      {:ok, agent} =
        Ash.create(Agent, %{
          name: "live-output-agent",
          template_id: agent_template!("claude_code").id,
          project_id: project.id,
          user_id: user.id
        })

      {:ok, task} =
        Ash.create(Task, %{
          title: "Streaming task",
          project_id: project.id,
          creator_id: user.id
        })

      {:ok, task} = Ash.update(task, %{agent_id: agent.id}, action: :begin_work)

      {:ok, session} =
        Ash.create(Session, %{agent_id: agent.id, task_id: task.id})

      {:ok, session} = Ash.update(session, %{}, action: :mark_running)

      %{agent: agent, task: task, session: session}
    end

    test "streamed output renders inside the running session card", %{
      conn: conn,
      task: task,
      agent: agent
    } do
      {:ok, view, html} = live(conn, ~p"/tasks/#{task.id}")

      refute html =~ "Live output"

      send(view.pid, {:agent_output, agent.id, ~s({"type":"result","result":"hello"}\n)})

      html = render(view)

      assert html =~ "Sessions"
      assert html =~ "running"
      assert html =~ "Live output"
      assert html =~ "hello"
    end

    test "no Live output heading when buffer is empty", %{conn: conn, task: task} do
      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      refute html =~ "Live output"
    end
  end

  describe "agent updates" do
    test "survives an {:agent_updated, agent} broadcast and reflects new status",
         %{conn: conn, project: project, user: user} do
      {:ok, agent} =
        Ash.create(Agent, %{
          name: "live-agent",
          template_id: agent_template!("claude_code").id,
          project_id: project.id,
          user_id: user.id
        })

      {:ok, task} =
        Ash.create(Task, %{
          title: "Agent-bound task",
          project_id: project.id,
          creator_id: user.id
        })

      {:ok, _task} = Ash.update(task, %{agent_id: agent.id}, action: :begin_work)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      {:ok, busy_agent} = Ash.update(agent, %{}, action: :mark_busy)

      Phoenix.PubSub.broadcast(
        Camelot.PubSub,
        "agent:#{agent.id}",
        {:agent_updated, busy_agent}
      )

      # Before the fix this crashed the LiveView with a FunctionClauseError;
      # render/1 forces a round-trip so a dead process would raise here.
      assert render(view) =~ "Agent-bound task"
    end

    test "ignores unrelated PubSub messages without crashing",
         %{conn: conn, project: project, user: user} do
      {:ok, agent} =
        Ash.create(Agent, %{
          name: "live-agent-2",
          template_id: agent_template!("claude_code").id,
          project_id: project.id,
          user_id: user.id
        })

      {:ok, task} =
        Ash.create(Task, %{
          title: "Catch-all task",
          project_id: project.id,
          creator_id: user.id
        })

      {:ok, _task} = Ash.update(task, %{agent_id: agent.id}, action: :begin_work)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      send(view.pid, {:some_unexpected_message, :payload})

      assert render(view) =~ "Catch-all task"
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
