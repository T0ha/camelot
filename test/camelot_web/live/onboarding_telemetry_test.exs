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
  alias Camelot.Board.Task
  alias Camelot.Projects.Project

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

    assert Enum.count(all_captured("onboarding_step_completed", user.id)) == 1
  end

  # Clicking a step dismisses the guide, after which the modal never
  # auto-opens again — so the impression that used to carry the person
  # properties stops happening for exactly the users who engaged with
  # the guide. Three of the four steps also finish across a navigation
  # or a full page redirect, where `refresh/1` recomputes from scratch
  # and has no `false -> true` flip to see. Without a restatement on
  # mount the cohort shows them stuck at a step they already finished.
  test "progress is restated on mount once the guide is dismissed", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/projects")
    view |> element("button[phx-click=onboarding_dismiss]") |> render_click()

    {:ok, _credential} =
      Ash.create(Credential, %{kind: :claude_api_key, value: "sk-test", user_id: user.id})

    {:ok, _view, _html} = live(conn, ~p"/projects")

    assert %{properties: %{"$set" => person}} = captured("$set")
    assert person["has_claude_token"] == true
    assert person["onboarding_next_step"] == "project"
  end

  # `$set` is PostHog's own person-update event: it keeps the cohort
  # current without putting a product event nobody asked for into
  # everyone's funnel.
  test "the restatement is a person update, not a product event", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/projects")
    view |> element("button[phx-click=onboarding_dismiss]") |> render_click()

    {:ok, _view, _html} = live(conn, ~p"/projects")

    assert Enum.count(all_captured("onboarding_shown", user.id)) == 1
    assert %{properties: properties} = captured("$set")
    refute Map.has_key?(properties, :steps_done)
  end

  test "re-opening the guide from the strip counts as an impression", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/projects")
    view |> element("button[phx-click=onboarding_dismiss]") |> render_click()

    view |> element("button[phx-click=onboarding_open]") |> render_click()

    assert Enum.count(all_captured("onboarding_shown", user.id)) == 2
  end

  # The profile page is where the Claude token step is really
  # finished. It nudges the guide, which is what lets the hook see the
  # transition at all — without it the step completes in silence.
  test "adding a credential on the profile page reports the step", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/profile")

    view
    |> form("#credential-form",
      credential: %{kind: "claude_api_key", name: "key", value: "sk-test"}
    )
    |> render_submit()

    # The nudge is a message to self/0, so it is handled after the
    # submit returns; this round-trip is what waits for it.
    render(view)

    assert %{properties: properties} = captured("onboarding_step_completed")
    assert properties.step == "claude_token"
    assert properties["$set"]["has_claude_token"] == true
    assert Enum.count(all_captured("onboarding_step_completed", user.id)) == 1
  end

  # The guide is just as often finished across a navigation as inside
  # one — connecting the App redirects to /profile, saving a project
  # pushes to /projects — and a fresh mount reaches completion through
  # `install/2`, which has no `false -> true` flip to report and so
  # restates nothing. Left there, the person properties keep whatever
  # they held when the guide was last on screen, and the account that
  # finished stays in the "stuck at step X" cohort for good.
  test "finishing the guide across a navigation restates the person", %{
    conn: conn,
    user: user
  } do
    finish_every_step!(user)

    {:ok, _view, _html} = live(conn, ~p"/projects")

    assert %{properties: %{"$set" => person}} = captured("onboarding_completed")
    assert person["onboarding_next_step"] == ""
    assert person["has_claude_token"] == true
    assert person["has_project"] == true
    assert person["has_task"] == true
  end

  # Every applicable step, done the way the product does it, before
  # the guide is ever rendered — which is what forces completion
  # through the mount path rather than through a refresh.
  defp finish_every_step!(user) do
    {:ok, _credential} =
      Ash.create(Credential, %{kind: :claude_api_key, value: "sk-test", user_id: user.id})

    {:ok, project} =
      Ash.create(
        Project,
        %{name: "onboarding-#{System.unique_integer([:positive])}"},
        actor: user
      )

    {:ok, _task} =
      Ash.create(Task, %{
        title: "Onboarding task",
        project_id: project.id,
        creator_id: user.id,
        agent_id: agent!("claude_code").id
      })

    :ok
  end

  defp captured(event), do: Enum.find(PostHog.Test.all_captured(), &(&1.event == event))

  # The shared-mode stash is owned by `setup_all` and so accumulates
  # across the whole module. `captured/1` is unaffected — the stash is
  # newest-first — but a count has to name the user it is about, or it
  # asserts over every test in the file rather than this one.
  defp all_captured(event, distinct_id) do
    Enum.filter(
      PostHog.Test.all_captured(),
      &(&1.event == event and &1.distinct_id == distinct_id)
    )
  end
end
