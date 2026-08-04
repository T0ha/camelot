defmodule CamelotWeb.SessionDownloadControllerTest do
  use CamelotWeb.ConnCase, async: true

  alias Camelot.Agents.Agent
  alias Camelot.Agents.Session
  alias Camelot.Board.Task
  alias Camelot.Projects.Project

  setup %{conn: conn} do
    %{conn: conn, user: user} = register_and_log_in_user(%{conn: conn})

    {:ok, project} =
      Ash.create(
        Project,
        %{name: "session-download-proj", path: "/tmp/session-download-proj"},
        actor: user
      )

    {:ok, agent} =
      Ash.create(Agent, %{
        name: "session-download-agent",
        template_id: agent_template!("claude_code").id,
        project_id: project.id,
        user_id: user.id
      })

    {:ok, task} =
      Ash.create(Task, %{
        title: "Download task",
        project_id: project.id,
        creator_id: user.id
      })

    {:ok, session} = Ash.create(Session, %{agent_id: agent.id, task_id: task.id})

    {:ok, session} =
      Ash.update(session, %{output_log: "{\"line\":1}\n", exit_code: 0}, action: :complete)

    %{conn: conn, user: user, project: project, session: session}
  end

  describe "GET /sessions/:id/download" do
    test "streams the session's output_log as an attachment", %{conn: conn, session: session} do
      conn = get(conn, ~p"/sessions/#{session.id}/download")

      assert response(conn, 200) == "{\"line\":1}\n"
      assert get_resp_header(conn, "content-type") == ["application/x-ndjson"]

      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment"
      assert disposition =~ "session-#{session.id}.ndjson"
    end

    test "returns 404 for a user who isn't a member of the session's project", %{
      session: session
    } do
      conn = Phoenix.ConnTest.build_conn()
      %{conn: conn} = register_and_log_in_user(%{conn: conn})

      conn = get(conn, ~p"/sessions/#{session.id}/download")

      assert conn.status == 404
    end

    test "returns 404 for an anonymous request" do
      conn = Phoenix.ConnTest.build_conn()

      conn = get(conn, ~p"/sessions/#{Ash.UUID.generate()}/download")

      assert conn.status == 404
    end

    test "an admin can download any session's log", %{session: session} do
      conn = Phoenix.ConnTest.build_conn()
      %{conn: conn} = register_and_log_in_admin(%{conn: conn})

      conn = get(conn, ~p"/sessions/#{session.id}/download")

      assert response(conn, 200) == "{\"line\":1}\n"
    end
  end
end
