defmodule CamelotWeb.BoardLiveTest do
  use CamelotWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  test "renders board page", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "Board"
    assert html =~ "Todo"
    assert html =~ "Planning"
    assert html =~ "Executing"
    assert html =~ "Done"
  end
end
