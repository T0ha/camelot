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
