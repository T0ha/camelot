defmodule CamelotWeb.BoardTelemetryTest do
  @moduledoc """
  PostHog's dead clicks cluster on the new-task modal's project and
  agent selects: people open "create task" before they have anything
  to create one against, and the empty modal produced no signal at
  all.

  The board now refuses the dead end — a project-less user is sent to
  `/projects`, and an agent whose API key is absent is disabled — so
  these pin that each refusal is still counted exactly once, and that
  an equipped user is not counted at all.

  Runs in shared PostHog mode because the capture happens inside the
  LiveView process rather than the test's own.
  """
  use CamelotWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Camelot.Accounts.Credential
  alias Camelot.Projects.Project

  setup_all {PostHog.Test, :set_posthog_shared}

  setup :register_and_log_in_user

  test "being sent off a project-less board reports the dead end", ctx do
    assert {:error, {:live_redirect, %{to: "/projects"}}} = live(ctx.conn, ~p"/")

    assert %{distinct_id: distinct_id, properties: properties} = captured_block(ctx.user.id)
    assert distinct_id == ctx.user.id
    assert properties.reason == :no_project
  end

  # The guide's last step links to the board with the modal already
  # open, so the click that would otherwise report this never happens.
  test "the setup guide's last step reports it without a click", ctx do
    assert {:error, {:live_redirect, %{to: "/projects"}}} =
             live(ctx.conn, ~p"/?onboarding=task")

    assert %{properties: %{reason: :no_project}} = captured_block(ctx.user.id)
  end

  test "opening the modal with no API key for any agent reports it", ctx do
    project!(ctx.user)

    {:ok, view, _html} = live(ctx.conn, ~p"/")

    view |> element("button", "New Task") |> render_click()

    assert %{properties: %{reason: :no_credential}} = captured_block(ctx.user.id)
  end

  # Re-opening the modal is the same dead end, and counting it twice
  # would make the funnel's denominator the number of clicks rather
  # than the number of users who hit it.
  test "the same dead end is reported once per session", ctx do
    project!(ctx.user)

    {:ok, view, _html} = live(ctx.conn, ~p"/")

    view |> element("button", "New Task") |> render_click()
    render_click(view, "close_new_task")
    view |> element("button", "New Task") |> render_click()

    assert [_one] = all_blocks(ctx.user.id)
  end

  test "a fully equipped user is not counted as blocked", ctx do
    claude_key!(ctx.user)
    project!(ctx.user)

    {:ok, view, _html} = live(ctx.conn, ~p"/")

    view |> element("button", "New Task") |> render_click()

    assert all_blocks(ctx.user.id) == []
  end

  defp project!(user) do
    Ash.create!(
      Project,
      %{
        name: "board-telemetry-#{System.unique_integer([:positive])}",
        path: "/tmp/board-telemetry"
      },
      actor: user
    )
  end

  defp claude_key!(user) do
    Ash.create!(
      Credential,
      %{kind: :claude_api_key, value: "sk-ant-telemetry", user_id: user.id}
    )
  end

  # The shared-mode stash is owned by `setup_all`, so it accumulates
  # across the module's tests: every assertion has to name the user it
  # is about rather than ask whether the event exists at all.
  defp all_blocks(distinct_id) do
    Enum.filter(
      PostHog.Test.all_captured(),
      &(&1.event == "task_form_blocked" and &1.distinct_id == distinct_id)
    )
  end

  defp captured_block(distinct_id), do: distinct_id |> all_blocks() |> List.first()
end
