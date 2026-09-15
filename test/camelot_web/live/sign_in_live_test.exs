defmodule CamelotWeb.SignInLiveTest do
  use CamelotWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "offers both the GitHub button and the magic-link form", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/sign-in")

    assert html =~ ~s(href="/auth/user/github")
    assert html =~ "Sign in with Github"
    assert html =~ "user[email]"
  end
end
