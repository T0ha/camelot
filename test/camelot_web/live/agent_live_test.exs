defmodule CamelotWeb.AgentLiveTest do
  use CamelotWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Camelot.Agents.Agent
  alias Camelot.Projects.Project

  setup :register_and_log_in_user

  setup do
    {:ok, project} =
      Ash.create(Project, %{
        name: "agent-live-proj",
        path: "/tmp/agent-live-proj"
      })

    {:ok, agent} =
      Ash.create(Agent, %{
        name: "LiveAgent",
        type: :claude_code,
        project_id: project.id
      })

    %{agent: agent, project: project}
  end

  describe "Index" do
    test "lists agents", %{conn: conn, agent: agent} do
      {:ok, _view, html} = live(conn, ~p"/agents")
      assert html =~ "Agents"
      assert html =~ agent.name
    end
  end

  describe "Show" do
    test "shows agent detail",
         %{conn: conn, agent: agent} do
      {:ok, _view, html} =
        live(conn, ~p"/agents/#{agent.id}")

      assert html =~ agent.name
      assert html =~ "claude_code"
      assert html =~ "idle"
    end
  end
end
