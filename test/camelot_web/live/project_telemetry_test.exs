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

  describe "repository resolution" do
    test "a repo owner no installation covers is reported", %{conn: conn, user: user} do
      github_installation!(user, %{account_login: "alice"})
      github_installation!(user, %{account_login: "beta-org"})

      create_project(conn, user, %{"github_owner" => "bigcorp", "github_repo" => "widgets"})

      assert %{properties: properties} = captured_resolve_failure(user)
      assert properties.reason == :repo_not_in_installation
      assert properties.http_status == nil
    end

    # The sole-installation fallback in `Camelot.Github.Resolver` hands
    # the runner *an* installation whether or not it covers the owner,
    # so "the user has exactly one installation" is precisely the case
    # a coarser check would call resolved.
    test "the sole-installation fallback does not count as covered", %{conn: conn, user: user} do
      github_installation!(user, %{account_login: "alice"})

      create_project(conn, user, %{"github_owner" => "bigcorp", "github_repo" => "widgets"})

      assert %{properties: properties} = captured_resolve_failure(user)
      assert properties.reason == :repo_not_in_installation
    end

    test "a user with no installation at all is reported", %{conn: conn, user: user} do
      create_project(conn, user, %{"github_owner" => "bigcorp", "github_repo" => "widgets"})

      assert %{properties: properties} = captured_resolve_failure(user)
      assert properties.reason == :no_installation
    end

    test "a covered repo owner is not reported", %{conn: conn, user: user} do
      github_installation!(user, %{account_login: "BigCorp"})

      create_project(conn, user, %{"github_owner" => "bigcorp", "github_repo" => "widgets"})

      refute captured_resolve_failure(user)
    end

    test "a project with no GitHub repo is not reported", %{conn: conn, user: user} do
      create_project(conn, user, %{})

      refute captured_resolve_failure(user)
    end
  end

  defp create_project(conn, user, attrs) do
    {:ok, view, _html} = live(conn, ~p"/projects/new")

    params = Map.put(attrs, "name", "telemetry-#{System.unique_integer([:positive])}")

    view |> form("#project-form", params) |> render_submit()

    assert captured(user, "project_created"),
           "the project was not created, so nothing could be resolved"
  end

  defp captured_create_failure do
    Enum.find(PostHog.Test.all_captured(), &(&1.event == "project_create_failed"))
  end

  # Shared mode stashes every capture the whole module makes, so an
  # assertion that is not scoped to this test's own user reads another
  # test's events.
  defp captured_resolve_failure(user), do: captured(user, "project_repo_resolve_failed")

  defp captured(%{id: user_id}, event) do
    Enum.find(
      PostHog.Test.all_captured(),
      &(&1.event == event and &1.distinct_id == user_id)
    )
  end
end
