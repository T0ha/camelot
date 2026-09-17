defmodule CamelotWeb.OnboardingLiveTest do
  use CamelotWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Camelot.Accounts.Credential
  alias Camelot.Accounts.User
  alias Camelot.Board.Task
  alias Camelot.Projects.Project

  setup :register_and_log_in_user

  @modal "#onboarding-welcome-modal"
  @open_modal "#onboarding-welcome-modal[open]"

  describe "welcome modal" do
    test "greets a brand new user on the board", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/")

      assert html =~ "Welcome to Camelot"
      assert has_element?(view, @open_modal)
    end

    test "greets a brand new user on any authenticated screen", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects")

      assert has_element?(view, @open_modal)
    end

    test "dismissing it persists and survives a remount", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/")

      render_click(view, "onboarding_dismiss")
      refute has_element?(view, @open_modal)

      assert %{onboarding_dismissed_at: %DateTime{}} = reload(user)

      {:ok, view, html} = live(conn, ~p"/")
      refute has_element?(view, @open_modal)
      assert has_element?(view, @modal)
      assert html =~ "onboarding-setup-bar"
    end

    test "can be re-opened from the setup bar", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      render_click(view, "onboarding_dismiss")
      render_click(view, "onboarding_open")

      assert has_element?(view, @open_modal)
    end

    test "onboarding_go dismisses and navigates to the step", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert {:error, {:live_redirect, %{to: "/projects/new"}}} =
               render_click(view, "onboarding_go", %{"step" => "project"})

      assert %{onboarding_dismissed_at: %DateTime{}} = reload(user)
    end

    test "onboarding_go ignores a step it never rendered", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert render_click(view, "onboarding_go", %{"step" => "../../admin"})

      assert has_element?(view, @open_modal)
      assert %{onboarding_dismissed_at: nil} = reload(user)
    end
  end

  describe "setup bar" do
    test "renders the pending steps while setup is incomplete", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "onboarding-setup-bar"
      assert html =~ "Add a Claude token"
      assert html =~ "Create a project"
      assert html =~ "Create a task"
    end

    test "is gone once every applicable step is done", %{conn: conn, user: user} do
      complete_setup(user)

      {:ok, _view, html} = live(conn, ~p"/")

      refute html =~ "onboarding-setup-bar"
      refute html =~ "onboarding-welcome-modal"
    end

    test "first mount of a fully set up user stamps onboarding_completed_at", %{
      conn: conn,
      user: user
    } do
      complete_setup(user)

      {:ok, _view, _html} = live(conn, ~p"/")

      assert %{onboarding_completed_at: %DateTime{}} = reload(user)
    end

    test "a user who already completed onboarding sees neither", %{conn: conn, user: user} do
      Ash.update!(user, %{}, action: :complete_onboarding, actor: user)

      {:ok, _view, html} = live(conn, ~p"/")

      refute html =~ "onboarding-setup-bar"
      refute html =~ "onboarding-welcome-modal"
    end

    test "ticks a step on the next navigation that completed it", %{
      conn: conn,
      user: user
    } do
      {:ok, view, html} = live(conn, ~p"/projects")
      assert html =~ "onboarding-step-project-pending"

      seed_project(user)

      assert render_patch(view, ~p"/projects") =~ "onboarding-step-project-done"
    end
  end

  describe "task step hand-off" do
    test "?onboarding=task opens the New Task modal", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/?onboarding=task")

      assert html =~ "new-task-modal"
      assert html =~ "phx-mounted"
    end

    test "creating a task completes onboarding without a reload", %{conn: conn, user: user} do
      seed_claude_token(user)
      project = seed_project(user)

      {:ok, view, html} = live(conn, ~p"/?onboarding=task")
      assert html =~ "onboarding-setup-bar"

      view
      |> form("#new-task-form", %{
        "task" => %{
          "title" => "First task",
          "description" => "kick the tyres",
          "project_id" => project.id,
          "agent_id" => agent!("claude_code").id
        }
      })
      |> render_submit()

      html = render(view)
      refute html =~ "onboarding-setup-bar"
      refute html =~ "onboarding-welcome-modal"
      assert %{onboarding_completed_at: %DateTime{}} = reload(user)
    end
  end

  defp reload(user), do: Ash.get!(User, user.id, authorize?: false)

  defp seed_claude_token(user) do
    Ash.create!(
      Credential,
      %{kind: :claude_api_key, value: "sk-ant-test", user_id: user.id}
    )
  end

  defp seed_project(user) do
    Ash.create!(
      Project,
      %{name: "onboarding-#{System.unique_integer([:positive])}", path: "/tmp/onboarding"},
      actor: user
    )
  end

  defp complete_setup(user) do
    seed_claude_token(user)
    project = seed_project(user)

    Ash.create!(Task, %{
      title: "First task",
      project_id: project.id,
      creator_id: user.id,
      agent_id: agent!("claude_code").id
    })
  end
end
