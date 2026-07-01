defmodule Camelot.Runtime.EnvVarResolverTest do
  use Camelot.DataCase, async: true

  alias Camelot.Agents.Agent
  alias Camelot.Projects.EnvVar
  alias Camelot.Projects.Project
  alias Camelot.Runtime.EnvVarResolver

  defp setup_agent do
    user = user!()

    {:ok, project} =
      Ash.create(Project, %{name: "res-#{System.unique_integer([:positive])}", path: "/tmp/r"})

    template = agent_template!("claude_code")

    {:ok, agent} =
      Ash.create(Agent, %{
        name: "Res-#{System.unique_integer([:positive])}",
        template_id: template.id,
        project_id: project.id,
        user_id: user.id
      })

    %{agent: agent, project: project, user: user}
  end

  test "collects vars matching the agent's scopes and decrypts them" do
    %{agent: agent, project: project, user: user} = setup_agent()

    Ash.create!(EnvVar, %{key: "G", value: "global"})
    Ash.create!(EnvVar, %{key: "U", value: "user", user_id: user.id})
    Ash.create!(EnvVar, %{key: "A", value: "agent", agent_id: agent.id})
    Ash.create!(EnvVar, %{key: "P", value: "project", project_id: project.id})

    assert EnvVarResolver.resolve(agent) == %{
             "G" => "global",
             "U" => "user",
             "A" => "agent",
             "P" => "project"
           }
  end

  test "project beats agent beats user beats global on key collision" do
    %{agent: agent, project: project, user: user} = setup_agent()

    Ash.create!(EnvVar, %{key: "K", value: "global"})
    Ash.create!(EnvVar, %{key: "K", value: "user", user_id: user.id})
    Ash.create!(EnvVar, %{key: "K", value: "agent", agent_id: agent.id})
    Ash.create!(EnvVar, %{key: "K", value: "project", project_id: project.id})

    assert %{"K" => "project"} = EnvVarResolver.resolve(agent)
  end

  test "agent wins when no project-scoped override exists" do
    %{agent: agent, user: user} = setup_agent()

    Ash.create!(EnvVar, %{key: "K", value: "user", user_id: user.id})
    Ash.create!(EnvVar, %{key: "K", value: "agent", agent_id: agent.id})

    assert %{"K" => "agent"} = EnvVarResolver.resolve(agent)
  end

  test "excludes vars scoped to a different project or user" do
    %{agent: agent} = setup_agent()

    other_user = user!()
    {:ok, other_project} = Ash.create(Project, %{name: "other-#{System.unique_integer([:positive])}"})

    Ash.create!(EnvVar, %{key: "OTHER_U", value: "x", user_id: other_user.id})
    Ash.create!(EnvVar, %{key: "OTHER_P", value: "y", project_id: other_project.id})

    resolved = EnvVarResolver.resolve(agent)
    refute Map.has_key?(resolved, "OTHER_U")
    refute Map.has_key?(resolved, "OTHER_P")
  end

  test "returns empty map when nothing applies" do
    %{agent: agent} = setup_agent()
    assert EnvVarResolver.resolve(agent) == %{}
  end
end
