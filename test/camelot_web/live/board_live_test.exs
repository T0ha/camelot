defmodule CamelotWeb.BoardLiveTest do
  use CamelotWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Camelot.Agents.Session
  alias Camelot.Board.Task
  alias Camelot.Projects.Project

  require Ash.Query

  setup :register_and_log_in_user

  test "renders board page", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "Board"
    assert html =~ "Todo"
    assert html =~ "Planning"
    assert html =~ "Executing"
    assert html =~ "Done"
    refute html =~ "Draft"
  end

  test "ignores unrelated PubSub messages without crashing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    send(view.pid, {:some_unexpected_message, :payload})

    assert render(view) =~ "Board"
  end

  test "New Task form clears fields after successful creation", %{conn: conn, user: user} do
    {:ok, project} =
      Ash.create(
        Project,
        %{name: "p-#{System.unique_integer()}", path: "/tmp/z"},
        actor: user
      )

    {:ok, view, _html} = live(conn, ~p"/")

    render_click(view, "open_new_task")

    task_form =
      form(view, "#new-task-form", %{
        "task" => %{
          "title" => "Write the plan",
          "description" => "some details",
          "project_id" => project.id,
          "agent_id" => agent!("claude_code").id,
          "priority" => "2"
        }
      })

    render_change(task_form)
    html = render_submit(task_form)

    form_html = view |> element("#new-task-form") |> render()
    refute form_html =~ "Write the plan"
    refute form_html =~ "some details"
    refute html =~ ~r/<dialog[^>]*id="new-task-modal"[^>]*\sopen/
  end

  test "New Task form reports missing project and agent inline", %{conn: conn} do
    title = "missing-selects-#{System.unique_integer()}"
    {:ok, view, _html} = live(conn, ~p"/")

    render_click(view, "open_new_task")

    html =
      view
      |> form("#new-task-form", %{
        "task" => %{
          "title" => title,
          "description" => "some details",
          "project_id" => "",
          "agent_id" => "",
          "priority" => "2"
        }
      })
      |> render_submit()

    assert html =~ "is required"
    assert html =~ ~r/<dialog[^>]*id="new-task-modal"[^>]*\sopen/
    refute Task |> Ash.Query.filter(title == ^title) |> Ash.read_one!()
  end

  test "New Task form falls back to the default priority when it is cleared", %{
    conn: conn,
    user: user
  } do
    title = "blank-priority-#{System.unique_integer()}"

    {:ok, project} =
      Ash.create(
        Project,
        %{name: "p-#{System.unique_integer()}", path: "/tmp/prio"},
        actor: user
      )

    {:ok, view, _html} = live(conn, ~p"/")

    render_click(view, "open_new_task")

    view
    |> form("#new-task-form", %{
      "task" => %{
        "title" => title,
        "description" => "some details",
        "project_id" => project.id,
        "agent_id" => agent!("claude_code").id,
        "priority" => ""
      }
    })
    |> render_submit()

    task = Task |> Ash.Query.filter(title == ^title) |> Ash.read_one!()
    assert task.priority == 0
  end

  test "restart_task resets an errored task back to queued", %{conn: conn, user: user} do
    {:ok, project} =
      Ash.create(
        Project,
        %{name: "p-#{System.unique_integer()}", path: "/tmp/r"},
        actor: user
      )

    task =
      Ash.Seed.seed!(Task, %{
        title: "stuck-task-#{System.unique_integer()}",
        project_id: project.id,
        creator_id: user.id,
        stage: :executing,
        state: :error
      })

    {:ok, view, _html} = live(conn, ~p"/")

    render_click(view, "restart_task", %{"id" => task.id})

    assert Ash.get!(Task, task.id).state == :queued
  end

  describe "attachments" do
    setup %{user: user} do
      {:ok, project} =
        Ash.create(
          Project,
          %{name: "attach-board-#{System.unique_integer()}", path: "/tmp/a"},
          actor: user
        )

      on_exit(fn ->
        System.tmp_dir!()
        |> Path.join("camelot-attachments")
        |> File.rm_rf()
      end)

      %{project: project}
    end

    test "uploading a file on the New Task form attaches it to the created task", %{
      conn: conn,
      project: project
    } do
      title = "New task with attachment #{System.unique_integer()}"
      {:ok, view, _html} = live(conn, ~p"/")

      file =
        file_input(view, "#new-task-form", :attachment, [
          %{name: "spec.txt", content: "some spec", type: "text/plain"}
        ])

      render_upload(file, "spec.txt")

      task_form =
        form(view, "#new-task-form", %{
          "task" => %{
            "title" => title,
            "description" => "some details",
            "project_id" => project.id,
            "agent_id" => agent!("claude_code").id,
            "priority" => "2"
          }
        })

      render_submit(task_form)

      task =
        Task
        |> Ash.Query.filter(title == ^title)
        |> Ash.read_one!(load: :attachments)

      assert [%{filename: "spec.txt"}] = task.attachments
    end

    test "failed task creation does not attach the staged file", %{conn: conn} do
      title = "Failed task with attachment #{System.unique_integer()}"
      {:ok, view, _html} = live(conn, ~p"/")

      file =
        file_input(view, "#new-task-form", :attachment, [
          %{name: "spec.txt", content: "some spec", type: "text/plain"}
        ])

      render_upload(file, "spec.txt")

      task_form =
        form(view, "#new-task-form", %{
          "task" => %{
            "title" => title,
            "description" => "some details",
            "project_id" => "",
            "agent_id" => "",
            "priority" => "2"
          }
        })

      render_submit(task_form)

      refute Task |> Ash.Query.filter(title == ^title) |> Ash.read_one!()
    end
  end

  describe "runner slot badge" do
    setup %{user: user} do
      {:ok, project} =
        Ash.create(
          Project,
          %{name: "slot-#{System.unique_integer()}", path: "/tmp/slot"},
          actor: user
        )

      %{project: project}
    end

    test "a dispatched task waiting on a runner slot shows the waiting badge", %{
      conn: conn,
      user: user,
      project: project
    } do
      task =
        Ash.Seed.seed!(Task, %{
          title: "waiting-task-#{System.unique_integer()}",
          project_id: project.id,
          creator_id: user.id,
          agent_id: agent!("claude_code").id,
          stage: :executing,
          state: :in_progress
        })

      {:ok, _session} =
        Ash.create(Session, %{agent_id: task.agent_id, task_id: task.id})

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "Waiting for a runner slot"
    end

    test "a task whose session is running shows the in progress badge", %{
      conn: conn,
      user: user,
      project: project
    } do
      task =
        Ash.Seed.seed!(Task, %{
          title: "running-task-#{System.unique_integer()}",
          project_id: project.id,
          creator_id: user.id,
          agent_id: agent!("claude_code").id,
          stage: :executing,
          state: :in_progress
        })

      Ash.Seed.seed!(Session, %{
        agent_id: task.agent_id,
        task_id: task.id,
        status: :running
      })

      {:ok, _view, html} = live(conn, ~p"/")

      refute html =~ "Waiting for a runner slot"
      assert html =~ ~s(title="In progress")
    end
  end

  describe "scoping" do
    test "non-admin sees only tasks from member projects", %{conn: conn, user: user} do
      {:ok, mine} =
        Ash.create(
          Project,
          %{name: "mine-board-#{System.unique_integer()}", path: "/tmp/x"},
          actor: user
        )

      {:ok, _mine_task} =
        Ash.create(Task, %{
          title: "mine-task-#{System.unique_integer()}",
          project_id: mine.id,
          creator_id: user.id,
          agent_id: agent!("claude_code").id
        })

      other = Ash.Seed.seed!(Camelot.Accounts.User, %{email: "o-#{System.unique_integer()}@x.com"})

      {:ok, theirs} =
        Ash.create(
          Project,
          %{name: "theirs-board-#{System.unique_integer()}", path: "/tmp/y"},
          actor: other
        )

      {:ok, _theirs_task} =
        Ash.create(Task, %{
          title: "theirs-task-#{System.unique_integer()}",
          project_id: theirs.id,
          creator_id: other.id,
          agent_id: agent!("claude_code").id
        })

      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "mine-task-"
      refute html =~ "theirs-task-"
    end
  end
end
