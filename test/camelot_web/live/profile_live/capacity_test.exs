defmodule CamelotWeb.ProfileLive.CapacityTest do
  use CamelotWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Camelot.Agents.Session

  setup :register_and_log_in_user

  test "renders its own heading, page title and the pool counts", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/profile/capacity")

    assert has_element?(view, "h1", "Running capacity")
    assert page_title(view) =~ "Running capacity"
    assert html =~ "You — running"
    assert html =~ "You — queued"
    assert html =~ "Cluster — running"
  end

  test "survives a pool change and an unknown message", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/profile/capacity")

    send(view.pid, :pool_changed)
    send(view.pid, {:some_unexpected_message, :payload})

    assert render(view) =~ "You — running"
  end

  test "lists the user's recent bootstrap runs", %{conn: conn, user: user} do
    {:ok, session} =
      Ash.create(Session, %{
        agent_id: Camelot.DataCase.agent!("claude_code").id,
        user_id: user.id,
        kind: :bootstrap,
        bootstrap_kind: :prewarm
      })

    {:ok, view, html} = live(conn, ~p"/profile/capacity")

    assert html =~ "Recent bootstrap runs"
    assert has_element?(view, "#boot-#{session.id}", "prewarm")
  end

  test "hides the bootstrap list when there are no runs", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/profile/capacity")

    refute html =~ "Recent bootstrap runs"
  end
end
