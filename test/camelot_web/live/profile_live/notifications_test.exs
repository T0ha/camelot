defmodule CamelotWeb.ProfileLive.NotificationsTest do
  use CamelotWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  test "renders its own heading and page title", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/profile/notifications")

    assert has_element?(view, "h1", "Email notifications")
    assert html =~ "Email notifications"
    assert page_title(view) =~ "Email notifications"
  end

  test "ignores unrelated messages without crashing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/profile/notifications")

    send(view.pid, {:some_unexpected_message, :payload})

    assert render(view) =~ "Email notifications"
  end

  test "toggling a checkbox off and submitting persists the change", %{
    conn: conn,
    user: user
  } do
    {:ok, view, _html} = live(conn, ~p"/profile/notifications")

    view
    |> form("#notification-prefs-form", %{
      "prefs" => %{
        "notify_on_waiting_for_input" => "true",
        "notify_on_error" => "false",
        "notify_on_done" => "true"
      }
    })
    |> render_submit()

    updated = Ash.get!(Camelot.Accounts.User, user.id)
    refute updated.notify_on_error
    assert updated.notify_on_waiting_for_input
    assert updated.notify_on_done
  end

  test "shows a confirmation flash after saving", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/profile/notifications")

    html =
      view
      |> form("#notification-prefs-form", %{
        "prefs" => %{
          "notify_on_waiting_for_input" => "true",
          "notify_on_error" => "true",
          "notify_on_done" => "true"
        }
      })
      |> render_submit()

    assert html =~ "Preferences saved"
  end
end
