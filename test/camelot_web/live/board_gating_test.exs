defmodule CamelotWeb.BoardGatingTest do
  @moduledoc """
  The board's New Task form used to be reachable with nothing to
  submit it against: PostHog's dead clicks cluster on its Project and
  CLI Agent selects, and no external user had ever created a project.

  Two prerequisites, two different answers. A project-less board is
  empty by construction, so the board sends the user to `/projects`
  rather than rendering a form at all. An API key is per-agent and
  per-user, so the agent stays in the dropdown — disabled, labelled,
  and refused server-side — because the user can pick a different one.
  """
  use CamelotWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Camelot.Accounts.Credential
  alias Camelot.Board.Task
  alias Camelot.Projects.Membership
  alias Camelot.Projects.Project

  require Ash.Query

  setup :register_and_log_in_user

  @open_modal ~r/<dialog[^>]*id="new-task-modal"[^>]*\sopen/

  describe "a user with no project" do
    test "is sent to /projects instead of an empty board", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/projects"} = redirect}} =
               live(conn, ~p"/")

      assert redirect.flash["info"] =~ "Create a project first"
    end

    # The setup guide's last step deep-links to the board with the
    # modal already open — the one entry point that opened straight
    # onto the dead end.
    test "is sent to /projects even from the guide's task hand-off", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               live(conn, ~p"/?onboarding=task")
    end

    # The gate reads the board's own project list, not the guide's
    # status, so an account that finished (or predates) onboarding is
    # held to the same prerequisite.
    test "is sent to /projects even after completing onboarding", %{conn: conn, user: user} do
      Ash.update!(user, %{}, action: :complete_onboarding, actor: user)

      assert {:error, {:live_redirect, %{to: "/projects"}}} = live(conn, ~p"/")
    end

    # A board open in another tab while the user's last membership is
    # revoked must not reopen the form a fresh mount would have
    # redirected away from, however stale the DOM that pushes the
    # event.
    test "cannot reopen the modal after its last project disappears", %{
      conn: conn,
      user: user
    } do
      project = project!(user)
      {:ok, view, _html} = live(conn, ~p"/")

      Membership
      |> Ash.Query.filter(project_id == ^project.id)
      |> Ash.read!()
      |> Enum.each(&Ash.destroy!/1)

      send(view.pid, {:task_updated, nil})
      render_click(view, "open_new_task")

      refute render(view) =~ @open_modal
    end
  end

  describe "a user with a project but no API key" do
    setup %{user: user} do
      %{project: project!(user)}
    end

    test "reaches the board", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "Board"
    end

    test "sees every agent disabled and labelled", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      render_click(view, "open_new_task")
      html = view |> element("#new-task-form") |> render()

      assert html =~ "Claude Code — API key absent"
      assert html =~ "Codex — API key absent"
      assert html =~ ~r/<option[^>]*disabled/
      assert html =~ "No agent CLI has an API key yet"
    end

    test "names the missing kind once that agent is selected", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/")

      render_click(view, "open_new_task")

      html =
        view
        |> form("#new-task-form", %{
          "task" => %{
            "title" => "needs a key",
            "project_id" => project.id,
            "agent_id" => agent!("claude_code").id
          }
        })
        |> render_change()

      assert html =~ "Claude Code needs a claude_api_key credential"
    end

    # The disabled attribute is a hint to the browser, not a
    # guarantee: the submit has to refuse the same pick, or the run
    # only fails minutes later inside the runner with a bare 401.
    test "cannot submit a task against an agent it has no key for", %{
      conn: conn,
      project: project
    } do
      title = "no-key-#{System.unique_integer([:positive])}"
      {:ok, view, _html} = live(conn, ~p"/")

      render_click(view, "open_new_task")

      html =
        view
        |> form("#new-task-form", %{
          "task" => %{
            "title" => title,
            "project_id" => project.id,
            "agent_id" => agent!("claude_code").id
          }
        })
        |> render_submit()

      assert html =~ "Claude Code needs a claude_api_key credential"
      refute Task |> Ash.Query.filter(title == ^title) |> Ash.read_one!()
      # The typed values survive, so the user can switch agent rather
      # than retype the task.
      assert html =~ title
      assert html =~ @open_modal
    end
  end

  describe "a user with a project and an API key" do
    setup %{user: user} do
      claude_key!(user)

      %{project: project!(user)}
    end

    test "sees the unchanged New Task button and a populated form", %{
      conn: conn,
      project: project
    } do
      {:ok, view, html} = live(conn, ~p"/")

      assert html =~ "New Task"

      render_click(view, "open_new_task")
      form_html = view |> element("#new-task-form") |> render()

      assert form_html =~ project.name
      assert form_html =~ ~s(value="#{agent!("claude_code").id}")
      refute form_html =~ "Claude Code — API key absent"
      refute form_html =~ "No agent CLI has an API key yet"
    end

    # One key covers one CLI: the other agent stays visible but
    # unpickable, which is the whole reason this is a per-option state
    # rather than a gate on the button.
    test "still sees the agent it has no key for disabled", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      render_click(view, "open_new_task")
      html = view |> element("#new-task-form") |> render()

      assert html =~ "Codex — API key absent"
    end

    test "creates the task", %{conn: conn, project: project} do
      title = "with-key-#{System.unique_integer([:positive])}"
      {:ok, view, _html} = live(conn, ~p"/")

      render_click(view, "open_new_task")

      view
      |> form("#new-task-form", %{
        "task" => %{
          "title" => title,
          "project_id" => project.id,
          "agent_id" => agent!("claude_code").id
        }
      })
      |> render_submit()

      assert Task |> Ash.Query.filter(title == ^title) |> Ash.read_one!()
    end
  end

  defp project!(user) do
    Ash.create!(
      Project,
      %{
        name: "gating-#{System.unique_integer([:positive])}",
        path: "/tmp/board-gating"
      },
      actor: user
    )
  end

  defp claude_key!(user) do
    Ash.create!(
      Credential,
      %{kind: :claude_api_key, value: "sk-ant-gating", user_id: user.id}
    )
  end
end
