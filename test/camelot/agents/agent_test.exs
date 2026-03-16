defmodule Camelot.Agents.AgentTest do
  use Camelot.DataCase, async: true

  alias Camelot.Agents.Agent
  alias Camelot.Projects.Project

  setup do
    {:ok, project} =
      Ash.create(Project, %{
        name: "agent-proj",
        path: "/tmp/agent-proj"
      })

    %{project: project}
  end

  describe "create" do
    test "creates an agent with valid attrs", ctx do
      assert {:ok, agent} =
               Ash.create(Agent, %{
                 name: "Claude",
                 type: :claude_code,
                 project_id: ctx.project.id
               })

      assert agent.name == "Claude"
      assert agent.type == :claude_code
      assert agent.status == :idle
    end

    test "fails without name", ctx do
      assert {:error, _} =
               Ash.create(Agent, %{
                 type: :claude_code,
                 project_id: ctx.project.id
               })
    end

    test "enforces one agent per project", ctx do
      assert {:ok, _} =
               Ash.create(Agent, %{
                 name: "A1",
                 type: :claude_code,
                 project_id: ctx.project.id
               })

      assert {:error, _} =
               Ash.create(Agent, %{
                 name: "A2",
                 type: :codex,
                 project_id: ctx.project.id
               })
    end
  end

  describe "mark_busy / mark_idle" do
    test "transitions between idle and busy", ctx do
      {:ok, agent} =
        Ash.create(Agent, %{
          name: "Toggler",
          type: :claude_code,
          project_id: ctx.project.id
        })

      assert agent.status == :idle

      assert {:ok, busy} =
               Ash.update(agent, %{}, action: :mark_busy)

      assert busy.status == :busy

      assert {:ok, idle} =
               Ash.update(busy, %{}, action: :mark_idle)

      assert idle.status == :idle
    end
  end
end
