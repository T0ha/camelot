defmodule CamelotWeb.PostHogLiveNavigationTest do
  # Shared PostHog mode: `PostHog.Test`'s ownership attributes a
  # process's captures to the test that spawned it, but only the
  # *first* capture from that process establishes the ownership —
  # subsequent ones are dropped. A LiveView now captures the setup
  # guide's impression on mount, so the capture this test is about is
  # never the first one its LiveView makes.
  use CamelotWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup_all {PostHog.Test, :set_posthog_shared}

  setup :register_and_log_in_user

  test "in-place LiveView navigation refreshes the $current_url used by captured events", %{
    conn: conn
  } do
    name = "posthog-nav-#{System.unique_integer([:positive])}"

    {:ok, view, _html} = live(conn, ~p"/projects")

    render_patch(view, ~p"/projects/new")

    view
    |> form("#project-form", %{"name" => name, "path" => "/tmp/posthog-nav"})
    |> render_submit()

    assert %{properties: properties} =
             Enum.find(PostHog.Test.all_captured(), fn event ->
               event.event == "project_created" && event.properties[:"$current_url"]
             end)

    assert properties[:"$current_url"] =~ "/projects/new"
  end
end
