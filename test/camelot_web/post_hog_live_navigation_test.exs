defmodule CamelotWeb.PostHogLiveNavigationTest do
  use CamelotWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  test "in-place LiveView navigation refreshes the $current_url used by captured events", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/projects")

    render_patch(view, ~p"/projects/new")

    view
    |> form("#project-form", %{
      "name" => "posthog-nav-#{System.unique_integer([:positive])}",
      "path" => "/tmp/posthog-nav"
    })
    |> render_submit()

    assert %{properties: properties} =
             Enum.find(PostHog.Test.all_captured(), &(&1.event == "project_created"))

    assert properties[:"$current_url"] =~ "/projects/new"
  end
end
