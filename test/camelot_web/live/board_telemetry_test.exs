defmodule CamelotWeb.BoardTelemetryTest do
  @moduledoc """
  PostHog's dead clicks cluster on the new-task modal's project and
  agent selects: people open "create task" before they have anything
  to create one against, and the empty modal produced no signal at
  all.

  Gating the button is a separate question — this only pins that the
  dead end is countable, and that an equipped user is not counted.

  Runs in shared PostHog mode because the capture happens inside the
  LiveView process rather than the test's own.
  """
  use CamelotWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Camelot.Projects.Project

  setup_all {PostHog.Test, :set_posthog_shared}

  setup :register_and_log_in_user

  test "opening the modal with nothing to pick reports the dead end", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/")

    view |> element("button", "New Task") |> render_click()

    assert %{distinct_id: distinct_id, properties: properties} = captured_block()
    assert distinct_id == ctx.user.id
    assert properties.reason == :no_project
  end

  # The guide's last step links to the board with the modal already
  # open, so the click that would otherwise report this never happens.
  test "the setup guide's last step reports it without a click", ctx do
    {:ok, _view, _html} = live(ctx.conn, ~p"/?onboarding=task")

    assert %{properties: %{reason: :no_project}} = captured_block()
  end

  test "a user who already has a project is not counted as blocked", ctx do
    project!(ctx.user)

    {:ok, view, _html} = live(ctx.conn, ~p"/")

    view |> element("button", "New Task") |> render_click()

    refute captured_block(ctx.user.id)
  end

  defp project!(user) do
    {:ok, project} =
      Ash.create(
        Project,
        %{
          name: "board-telemetry-#{System.unique_integer([:positive])}",
          path: "/tmp/board-telemetry"
        },
        actor: user
      )

    project
  end

  # The shared-mode stash is owned by `setup_all`, so it accumulates
  # across the module's tests: a negative assertion has to name the
  # user it is about rather than ask whether the event exists at all.
  defp captured_block(distinct_id \\ nil) do
    PostHog.Test.all_captured()
    |> Enum.filter(&(&1.event == "task_form_blocked"))
    |> Enum.find(&(is_nil(distinct_id) or &1.distinct_id == distinct_id))
  end
end
