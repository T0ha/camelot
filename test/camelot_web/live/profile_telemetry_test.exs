defmodule CamelotWeb.ProfileTelemetryTest do
  @moduledoc """
  "Connect GitHub App" is a plain link out to GitHub, so the click is
  the only moment the application sees the attempt at all: without it
  a user who abandons GitHub's install screen is indistinguishable
  from one who never clicked, and the step reads as a total loss
  either way.

  Shared PostHog mode: the capture happens inside the LiveView
  process rather than the test's own.
  """
  use CamelotWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup_all {PostHog.Test, :set_posthog_shared}

  setup :register_and_log_in_user

  setup do
    Camelot.DataCase.stub_github_app()
  end

  test "following the connect link is counted as a started setup", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/profile")

    view |> element("a[phx-click=github_setup_started]") |> render_click()

    assert %{distinct_id: distinct_id} = captured_started(ctx.user.id)
    assert distinct_id == ctx.user.id
  end

  # The binding hangs off a real `href`, and the navigation has to
  # keep working: a capture that swallowed the click would cost a
  # conversion to measure one.
  test "the link still carries the GitHub install URL it navigates to", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/profile")

    href =
      view
      |> element("a[phx-click=github_setup_started]")
      |> render()

    assert href =~ "github.com/apps/camelot-dev/installations/new"
  end

  test "merely opening the profile is not a started setup", ctx do
    {:ok, _view, _html} = live(ctx.conn, ~p"/profile")

    refute captured_started(ctx.user.id)
  end

  # The shared-mode stash belongs to `setup_all`, so it accumulates
  # across the module's tests: every lookup names the user it is about.
  defp captured_started(distinct_id) do
    Enum.find(
      PostHog.Test.all_captured(),
      &(&1.event == "github_setup_started" and &1.distinct_id == distinct_id)
    )
  end
end
