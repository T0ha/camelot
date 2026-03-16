defmodule Camelot.Runtime.AgentProcessTest do
  use Camelot.DataCase, async: false

  alias Camelot.Accounts.User
  alias Camelot.Agents.Agent
  alias Camelot.Board.Task
  alias Camelot.Projects.Project
  alias Camelot.Runtime.AgentProcess
  alias Camelot.Runtime.AgentRegistry

  setup do
    {:ok, project} =
      Ash.create(Project, %{
        name: "proc-proj-#{System.unique_integer()}",
        path: "/tmp/proc-proj-#{System.unique_integer()}"
      })

    {:ok, agent} =
      Ash.create(Agent, %{
        name: "ProcAgent",
        type: :claude_code,
        project_id: project.id
      })

    {:ok, hashed} =
      AshAuthentication.BcryptProvider.hash("Hello world!123")

    user =
      Ash.Seed.seed!(User, %{
        email: "proc-#{System.unique_integer()}@example.com",
        hashed_password: hashed
      })

    {:ok, task} =
      Ash.create(Task, %{
        title: "Process task",
        project_id: project.id,
        creator_id: user.id
      })

    %{agent: agent, task: task}
  end

  describe "start_link/1" do
    test "starts and registers process", ctx do
      {:ok, pid} =
        AgentProcess.start_link(agent_id: ctx.agent.id)

      assert is_pid(pid)
      assert AgentRegistry.lookup(ctx.agent.id) == pid
    end
  end

  describe "status/1" do
    test "returns idle when no task running", ctx do
      {:ok, _pid} =
        AgentProcess.start_link(agent_id: ctx.agent.id)

      assert {:ok, :idle} = AgentProcess.status(ctx.agent.id)
    end

    test "returns not_found for unknown agent" do
      assert {:error, :not_found} =
               AgentProcess.status("nonexistent")
    end
  end

  describe "dispatch/3" do
    test "returns not_found for unregistered agent" do
      assert {:error, :not_found} =
               AgentProcess.dispatch(
                 "nonexistent",
                 "task-id",
                 "prompt"
               )
    end
  end
end
