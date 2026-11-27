defmodule CamelotWeb.SignInLiveTest do
  use CamelotWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    original = Application.get_env(:camelot, :magic_link_enabled)

    on_exit(fn ->
      Application.put_env(:camelot, :magic_link_enabled, original)
    end)

    :ok
  end

  test "offers both the GitHub button and the magic-link form", %{conn: conn} do
    Application.put_env(:camelot, :magic_link_enabled, true)
    {:ok, _view, html} = live(conn, ~p"/sign-in")

    assert html =~ ~s(href="/auth/user/github")
    assert html =~ "Sign in with Github"
    assert html =~ "user[email]"
    assert html =~ ~s(data-magic-link="on")
  end

  test "flags the page when magic link is disabled", %{conn: conn} do
    Application.put_env(:camelot, :magic_link_enabled, false)

    html = conn |> get(~p"/sign-in") |> html_response(200)

    assert html =~ ~s(data-magic-link="off")
    assert html =~ ~s(href="/auth/user/github")
  end
end
