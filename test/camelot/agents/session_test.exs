defmodule Camelot.Agents.SessionTest do
  use Camelot.DataCase, async: true

  alias Camelot.Accounts.User
  alias Camelot.Agents.Agent
  alias Camelot.Agents.Session
  alias Camelot.Board.Task
  alias Camelot.Projects.Project

  setup do
    {:ok, project} =
      Ash.create(Project, %{
        name: "session-proj",
        path: "/tmp/session-proj"
      })

    {:ok, agent} =
      Ash.create(Agent, %{
        name: "Agent",
        type: :claude_code,
        project_id: project.id
      })

    {:ok, hashed} =
      AshAuthentication.BcryptProvider.hash("Hello world!123")

    user =
      Ash.Seed.seed!(User, %{
        email: "session-test@example.com",
        hashed_password: hashed
      })

    {:ok, task} =
      Ash.create(Task, %{
        title: "Session task",
        project_id: project.id,
        creator_id: user.id
      })

    %{agent: agent, task: task}
  end

  describe "create" do
    test "creates a running session", ctx do
      assert {:ok, session} =
               Ash.create(Session, %{
                 agent_id: ctx.agent.id,
                 task_id: ctx.task.id
               })

      assert session.status == :running
      assert session.started_at
    end
  end

  describe "complete" do
    test "marks session as completed with output", ctx do
      {:ok, session} =
        Ash.create(Session, %{
          agent_id: ctx.agent.id,
          task_id: ctx.task.id
        })

      assert {:ok, completed} =
               Ash.update(
                 session,
                 %{
                   output_log: "Done!",
                   exit_code: 0
                 },
                 action: :complete
               )

      assert completed.status == :completed
      assert completed.output_log == "Done!"
      assert completed.exit_code == 0
      assert completed.finished_at
    end
  end

  describe "fail" do
    test "marks session as failed", ctx do
      {:ok, session} =
        Ash.create(Session, %{
          agent_id: ctx.agent.id,
          task_id: ctx.task.id
        })

      assert {:ok, failed} =
               Ash.update(
                 session,
                 %{output_log: "Error", exit_code: 1},
                 action: :fail
               )

      assert failed.status == :failed
      assert failed.exit_code == 1
    end
  end

  describe "cancel" do
    test "marks session as cancelled", ctx do
      {:ok, session} =
        Ash.create(Session, %{
          agent_id: ctx.agent.id,
          task_id: ctx.task.id
        })

      assert {:ok, cancelled} =
               Ash.update(session, %{}, action: :cancel)

      assert cancelled.status == :cancelled
      assert cancelled.finished_at
    end
  end
end
