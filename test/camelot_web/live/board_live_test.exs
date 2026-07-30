defmodule CamelotWeb.BoardLiveTest do
  use CamelotWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Camelot.Board.Task
  alias Camelot.Projects.Project

  setup :register_and_log_in_user

  test "renders board page", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "Board"
    assert html =~ "Todo"
    assert html =~ "Planning"
    assert html =~ "Executing"
    assert html =~ "Done"
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

    task_form =
      form(view, "#new-task-form", %{
        "title" => "Write the plan",
        "description" => "some details",
        "project_id" => project.id,
        "priority" => "2"
      })

    render_change(task_form)
    render_submit(task_form)

    form_html = view |> element("#new-task-form") |> render()
    refute form_html =~ "Write the plan"
    refute form_html =~ "some details"
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
          creator_id: user.id
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
          creator_id: other.id
        })

      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "mine-task-"
      refute html =~ "theirs-task-"
    end
  end
end
