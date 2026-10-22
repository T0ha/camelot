defmodule CamelotWeb.ProfileLive.UserMenuTest do
  use CamelotWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  test "authenticated pages render the avatar menu with every profile link",
       %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/projects")

    assert has_element?(view, "#user-menu[aria-label='Account menu']")

    initial = user.email |> to_string() |> String.first() |> String.upcase()
    assert has_element?(view, "#user-menu", initial)

    for path <- ~w(ssh-key notifications api-keys capacity github usage) do
      assert has_element?(view, "#user-menu-items a[href='/profile/#{path}']")
    end

    assert has_element?(view, "#user-menu-items", to_string(user.email))
    assert has_element?(view, "#user-menu-items a[href='/sign-out']", "Sign out")
  end

  test "the old Profile and Sign out buttons are gone", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/projects")

    refute html =~ ~s(<a href="/profile" class="btn btn-ghost btn-sm">)
    refute html =~ ~s(href="/sign-out" data-posthog-reset class="btn btn-ghost btn-sm")
  end

  test "signed-out visitors get no menu", %{conn: _conn} do
    conn = Phoenix.ConnTest.build_conn()
    html = conn |> Phoenix.ConnTest.get(~p"/sign-in") |> Phoenix.ConnTest.html_response(200)

    refute html =~ "user-menu"
  end
end
