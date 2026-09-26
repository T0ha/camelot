defmodule CamelotWeb.OnboardingTelemetryTest do
  @moduledoc """
  The setup guide is where an activation funnel either progresses or
  dies, and it emitted nothing at all before this.

  Shared PostHog mode: the captures happen inside the LiveView
  process, not the test's own.
  """
  use CamelotWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Camelot.Accounts.Credential

  setup_all {PostHog.Test, :set_posthog_shared}

  setup :register_and_log_in_user

  test "the guide reports its own impression, once, with progress", %{conn: conn} do
    {:ok, _view, _html} = live(conn, ~p"/projects")

    assert %{properties: properties} = captured("onboarding_shown")
    assert properties.steps_done == 0
    assert properties.steps_total > 0
    assert properties.next_step == "claude_token"
  end

  test "the impression sets the person properties the cohort needs", %{conn: conn} do
    {:ok, _view, _html} = live(conn, ~p"/projects")

    assert %{properties: %{"$set" => person}} = captured("onboarding_shown")
    assert person["onboarding_next_step"] == "claude_token"
    assert person["has_project"] == false
    assert person["has_task"] == false
  end

  test "clicking through to a step is captured with a bounded step name", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/projects")

    view |> element("button[phx-click=onboarding_go]") |> render_click()

    assert %{properties: %{step: "claude_token"}} = captured("onboarding_step_clicked")
  end

  test "dismissing the guide carries how far the user had got", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/projects")

    view |> element("button[phx-click=onboarding_dismiss]") |> render_click()

    assert %{properties: properties} = captured("onboarding_dismissed")
    assert properties.steps_done == 0
    assert properties.next_step == "claude_token"
  end

  # Clicking a step dismisses the guide as a side effect. Without
  # `via` the abandonment event would also fire for the most engaged
  # action in the guide, and the funnel could not tell them apart.
  test "a dismissal is distinguishable from a click-through", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/projects")

    view |> element("button[phx-click=onboarding_dismiss]") |> render_click()

    assert %{properties: %{via: "close"}} = captured("onboarding_dismissed")
  end

  test "clicking through a step marks the dismissal as a step click", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/projects")

    view |> element("button[phx-click=onboarding_go]") |> render_click()

    assert %{properties: %{via: "step_click"}} = captured("onboarding_dismissed")
  end

  # Only the false -> true flip: a navigation that changes nothing
  # must not re-report a step the user finished long ago.
  test "finishing a step is captured once, on the transition", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/projects")

    {:ok, _credential} =
      Ash.create(Credential, %{kind: :claude_api_key, value: "sk-test", user_id: user.id})

    render_patch(view, ~p"/projects")

    assert %{properties: properties} = captured("onboarding_step_completed")
    assert properties.step == "claude_token"
    assert properties["$set"]["has_claude_token"] == true

    render_patch(view, ~p"/projects")

    assert Enum.count(all_captured("onboarding_step_completed")) == 1
  end

  defp captured(event), do: Enum.find(PostHog.Test.all_captured(), &(&1.event == event))

  defp all_captured(event), do: Enum.filter(PostHog.Test.all_captured(), &(&1.event == event))
end
