defmodule CamelotWeb.ProjectTelemetryTest do
  @moduledoc """
  Project creation is where every external sign-up has stopped so
  far, and only its success was ever instrumented.

  Runs in shared PostHog mode because the capture happens inside the
  LiveView process rather than the test's own.
  """
  use CamelotWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup_all {PostHog.Test, :set_posthog_shared}

  setup :register_and_log_in_user

  test "a rejected form reports which fields failed and how", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/projects/new")

    view |> form("#project-form", %{"name" => ""}) |> render_submit()

    assert %{properties: properties} = captured_create_failure()
    assert "name" in properties.error_fields
    assert properties.error_codes != []
  end

  test "an unparseable advanced override is reported with its field", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/projects/new")

    view
    |> form("#project-form", %{
      "name" => "telemetry-#{System.unique_integer([:positive])}",
      "env_vars_override" => "{not json"
    })
    |> render_submit()

    assert %{properties: properties} = captured_create_failure()
    assert properties.error_fields == ["env_vars_override"]
    assert properties.error_codes == ["invalid_json"]
  end

  defp captured_create_failure do
    Enum.find(PostHog.Test.all_captured(), &(&1.event == "project_create_failed"))
  end
end
