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

    user = user!()
    claude = agent_template!("claude_code")
    codex = agent_template!("codex")

    %{project: project, user: user, claude: claude, codex: codex}
  end

  describe "create" do
    test "creates an agent with valid attrs", ctx do
      assert {:ok, agent} =
               Ash.create(Agent, %{
                 name: "Claude",
                 template_id: ctx.claude.id,
                 project_id: ctx.project.id,
                 user_id: ctx.user.id
               })

      assert agent.name == "Claude"
      assert agent.template_id == ctx.claude.id
      assert agent.status == :idle
    end

    test "fails without name", ctx do
      assert {:error, _} =
               Ash.create(Agent, %{
                 template_id: ctx.claude.id,
                 project_id: ctx.project.id,
                 user_id: ctx.user.id
               })
    end

    test "allows different templates for the same (project, user)", ctx do
      assert {:ok, _} =
               Ash.create(Agent, %{
                 name: "A1",
                 template_id: ctx.claude.id,
                 project_id: ctx.project.id,
                 user_id: ctx.user.id
               })

      assert {:ok, _} =
               Ash.create(Agent, %{
                 name: "A2",
                 template_id: ctx.codex.id,
                 project_id: ctx.project.id,
                 user_id: ctx.user.id
               })
    end
  end

  describe "mark_busy / mark_idle" do
    test "transitions between idle and busy", ctx do
      {:ok, agent} =
        Ash.create(Agent, %{
          name: "Toggler",
          template_id: ctx.claude.id,
          project_id: ctx.project.id,
          user_id: ctx.user.id
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
