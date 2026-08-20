defmodule Camelot.Runtime.EnvVarResolverTest do
  use Camelot.DataCase, async: true

  alias Camelot.Projects.EnvVar
  alias Camelot.Projects.Project
  alias Camelot.Runtime.EnvVarResolver

  defp setup_scope do
    user = user!()

    {:ok, project} =
      Ash.create(Project, %{name: "res-#{System.unique_integer([:positive])}", path: "/tmp/r"})

    agent = agent!("claude_code")

    %{agent: agent, project: project, user: user}
  end

  test "collects vars matching the task's scopes and decrypts them" do
    %{agent: agent, project: project, user: user} = setup_scope()

    Ash.create!(EnvVar, %{key: "G", value: "global"})
    Ash.create!(EnvVar, %{key: "U", value: "user", user_id: user.id})
    Ash.create!(EnvVar, %{key: "A", value: "agent", agent_id: agent.id})
    Ash.create!(EnvVar, %{key: "P", value: "project", project_id: project.id})

    assert EnvVarResolver.resolve(agent.id, project.id, user.id) == %{
             "G" => "global",
             "U" => "user",
             "A" => "agent",
             "P" => "project"
           }
  end

  test "project beats agent beats user beats global on key collision" do
    %{agent: agent, project: project, user: user} = setup_scope()

    Ash.create!(EnvVar, %{key: "K", value: "global"})
    Ash.create!(EnvVar, %{key: "K", value: "user", user_id: user.id})
    Ash.create!(EnvVar, %{key: "K", value: "agent", agent_id: agent.id})
    Ash.create!(EnvVar, %{key: "K", value: "project", project_id: project.id})

    assert %{"K" => "project"} = EnvVarResolver.resolve(agent.id, project.id, user.id)
  end

  test "agent wins when no project-scoped override exists" do
    %{agent: agent, user: user} = setup_scope()

    Ash.create!(EnvVar, %{key: "K", value: "user", user_id: user.id})
    Ash.create!(EnvVar, %{key: "K", value: "agent", agent_id: agent.id})

    assert %{"K" => "agent"} = EnvVarResolver.resolve(agent.id, nil, user.id)
  end

  test "excludes vars scoped to a different project or user" do
    %{agent: agent, project: project, user: user} = setup_scope()

    other_user = user!()
    {:ok, other_project} = Ash.create(Project, %{name: "other-#{System.unique_integer([:positive])}"})

    Ash.create!(EnvVar, %{key: "OTHER_U", value: "x", user_id: other_user.id})
    Ash.create!(EnvVar, %{key: "OTHER_P", value: "y", project_id: other_project.id})

    resolved = EnvVarResolver.resolve(agent.id, project.id, user.id)
    refute Map.has_key?(resolved, "OTHER_U")
    refute Map.has_key?(resolved, "OTHER_P")
  end

  test "returns empty map when nothing applies" do
    %{agent: agent, project: project, user: user} = setup_scope()
    assert EnvVarResolver.resolve(agent.id, project.id, user.id) == %{}
  end
end
