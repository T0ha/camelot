defmodule CamelotWeb.AgentLiveTest do
  use CamelotWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Camelot.Accounts.User
  alias Camelot.Agents.Agent
  alias Camelot.Projects.Project

  setup :register_and_log_in_user

  setup %{user: user} do
    {:ok, project} =
      Ash.create(
        Project,
        %{name: "agent-live-proj", path: "/tmp/agent-live-proj"},
        actor: user
      )

    template = agent_template!("claude_code")

    {:ok, agent} =
      Ash.create(Agent, %{
        name: "LiveAgent",
        template_id: template.id,
        project_id: project.id,
        user_id: user.id
      })

    %{agent: agent, project: project, template: template}
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
         %{conn: conn, agent: agent, template: template} do
      {:ok, _view, html} =
        live(conn, ~p"/agents/#{agent.id}")

      assert html =~ agent.name
      assert html =~ template.name
      assert html =~ "idle"
    end

    test "redirects non-owner / non-member from another user's agent", %{conn: conn} do
      other = Ash.Seed.seed!(User, %{email: "ao-#{System.unique_integer()}@x.com"})

      {:ok, project} =
        Ash.create(
          Project,
          %{name: "other-proj-#{System.unique_integer()}", path: "/tmp/op"},
          actor: other
        )

      template = agent_template!("claude_code")

      {:ok, agent} =
        Ash.create(Agent, %{
          name: "OtherAgent-#{System.unique_integer()}",
          template_id: template.id,
          project_id: project.id,
          user_id: other.id
        })

      assert {:error, {kind, %{to: "/agents"}}} =
               live(conn, ~p"/agents/#{agent.id}")

      assert kind in [:redirect, :live_redirect]
    end
  end

  describe "scoping" do
    test "non-admin sees own + project-member agents", %{conn: conn, agent: agent} do
      other = Ash.Seed.seed!(User, %{email: "ao-#{System.unique_integer()}@x.com"})

      {:ok, other_proj} =
        Ash.create(
          Project,
          %{name: "ext-proj-#{System.unique_integer()}", path: "/tmp/ext"},
          actor: other
        )

      template = agent_template!("claude_code")

      {:ok, other_agent} =
        Ash.create(Agent, %{
          name: "ExtAgent-#{System.unique_integer()}",
          template_id: template.id,
          project_id: other_proj.id,
          user_id: other.id
        })

      {:ok, _view, html} = live(conn, ~p"/agents")
      assert html =~ agent.name
      refute html =~ other_agent.name
    end
  end
end
