defmodule CamelotWeb.OnboardingTest do
  # async: false — several tests swap the deployment-wide
  # `:github_app` config to exercise the configured/not-configured
  # branches of the `:github` step.
  use Camelot.DataCase, async: false

  alias Camelot.Accounts.Credential
  alias Camelot.Board.Task
  alias Camelot.Projects.Project
  alias CamelotWeb.Onboarding
  alias CamelotWeb.Onboarding.Status

  @github_app [
    app_id: "123",
    slug: "camelot-dev",
    client_id: "Iv1.abc",
    client_secret: "secret",
    private_key: Base.encode64("-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----\n"),
    webhook_secret: "whsecret"
  ]

  setup do
    previous = Application.get_env(:camelot, :github_app)
    Application.put_env(:camelot, :github_app, @github_app)
    on_exit(fn -> Application.put_env(:camelot, :github_app, previous) end)

    %{user: user!()}
  end

  describe "status/1 step list" do
    test "a brand new user has every step pending", %{user: user} do
      assert %Status{complete?: false, next: :github} = status = Onboarding.status(user)

      assert status.steps == [
               github: false,
               claude_token: false,
               project: false,
               task: false
             ]
    end

    test "omits the github step when no GitHub App is configured", %{user: user} do
      Application.put_env(:camelot, :github_app, [])

      assert %Status{} = status = Onboarding.status(user)
      assert Keyword.keys(status.steps) == [:claude_token, :project, :task]
      assert status.next == :claude_token
    end

    test "counts only the applicable steps as complete", %{user: user} do
      Application.put_env(:camelot, :github_app, [])

      seed_claude_token(user)
      seed_task(user)

      assert %Status{complete?: true, next: nil} = Onboarding.status(user)
    end
  end

  describe "status/1 github step" do
    test "is done once a live installation is linked", %{user: user} do
      github_installation!(user)

      assert Onboarding.status(user).steps[:github]
    end

    test "is pending when the only installation is suspended", %{user: user} do
      github_installation!(user, %{suspended_at: DateTime.utc_now()})

      refute Onboarding.status(user).steps[:github]
    end

    test "ignores installations linked to another user", %{user: user} do
      github_installation!(user!())

      refute Onboarding.status(user).steps[:github]
    end
  end

  describe "status/1 remaining steps" do
    test "claude_token flips once a claude_api_key credential exists", %{user: user} do
      refute Onboarding.status(user).steps[:claude_token]

      seed_claude_token(user)

      assert Onboarding.status(user).steps[:claude_token]
    end

    test "another credential kind does not satisfy claude_token", %{user: user} do
      Ash.create!(
        Credential,
        %{kind: :openai_api_key, value: "sk-openai", user_id: user.id}
      )

      refute Onboarding.status(user).steps[:claude_token]
    end

    test "project flips once the user is a member of a project", %{user: user} do
      refute Onboarding.status(user).steps[:project]

      seed_project(user)

      assert Onboarding.status(user).steps[:project]
    end

    test "another user's project does not satisfy project", %{user: user} do
      seed_project(user!())

      refute Onboarding.status(user).steps[:project]
    end

    test "task flips once a task exists in one of the user's projects", %{user: user} do
      refute Onboarding.status(user).steps[:task]

      seed_task(user)

      assert Onboarding.status(user).steps[:task]
    end

    test "all four done means complete? with no next step", %{user: user} do
      github_installation!(user)
      seed_claude_token(user)
      seed_task(user)

      assert %Status{complete?: true, next: nil} = Onboarding.status(user)
    end
  end

  describe "dismiss!/1 and mark_complete!/1" do
    test "dismiss! stamps onboarding_dismissed_at", %{user: user} do
      assert is_nil(user.onboarding_dismissed_at)
      assert %{onboarding_dismissed_at: %DateTime{}} = Onboarding.dismiss!(user)
    end

    test "mark_complete! stamps onboarding_completed_at", %{user: user} do
      assert is_nil(user.onboarding_completed_at)
      assert %{onboarding_completed_at: %DateTime{}} = Onboarding.mark_complete!(user)
    end
  end

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

  defp seed_task(user) do
    project = seed_project(user)

    Ash.create!(Task, %{
      title: "First task",
      project_id: project.id,
      creator_id: user.id,
      agent_id: agent!("claude_code").id
    })
  end
end
