defmodule Camelot.Telemetry.PostHogHandlerTest do
  use Camelot.DataCase, async: true

  alias Camelot.Accounts.Credential
  alias Camelot.Accounts.User
  alias Camelot.Agents.Agent
  alias Camelot.Board.Task
  alias Camelot.Projects.Project
  alias Camelot.Telemetry.Context
  alias Camelot.Telemetry.Events
  alias Camelot.Telemetry.PostHogHandler

  setup do
    {:ok, project} =
      Ash.create(Project, %{
        name: "posthog-test-#{System.unique_integer([:positive])}",
        path: "/tmp/posthog-test"
      })

    %{project: project, user: user!()}
  end

  test "captures a curated event with the creator as distinct_id when no actor is present", ctx do
    assert {:ok, task} =
             Ash.create(Task, %{
               title: "PostHog task",
               project_id: ctx.project.id,
               creator_id: ctx.user.id,
               agent_id: agent!("claude_code").id
             })

    assert Enum.any?(PostHog.Test.all_captured(), fn event ->
             event.event == "task_created" && event.distinct_id == ctx.user.id && event.properties.data_id == task.id
           end)
  end

  test "captures a curated event with the actor as distinct_id when an actor is present", _ctx do
    actor = user!()

    assert {:ok, project} =
             Ash.create(
               Project,
               %{name: "posthog-actor-#{System.unique_integer([:positive])}"},
               actor: actor
             )

    assert Enum.any?(PostHog.Test.all_captured(), fn event ->
             event.event == "project_created" && event.distinct_id == actor.id &&
               event.properties.data_id == project.id
           end)
  end

  test "does not capture anything for actions with no curated mapping", ctx do
    {:ok, task} =
      Ash.create(Task, %{
        title: "Uncurated",
        project_id: ctx.project.id,
        creator_id: ctx.user.id,
        agent_id: agent!("claude_code").id
      })

    assert {:ok, _task} = Ash.update(task, %{title: "Renamed"})

    refute Enum.any?(PostHog.Test.all_captured(), &(&1.event == "task_updated"))
  end

  test "captures a user_signed_in identify-style event", ctx do
    :telemetry.execute([:camelot, :user, :signed_in], %{}, %{user: ctx.user})

    assert %{distinct_id: distinct_id, properties: properties} =
             Enum.find(PostHog.Test.all_captured(), &(&1.event == "user_signed_in"))

    assert distinct_id == ctx.user.id
    assert properties["$set"]["email"] == to_string(ctx.user.email)
    assert properties["$set"]["role"] == to_string(ctx.user.role)
  end

  test "merges the process's PostHog context into captured event properties", ctx do
    PostHog.set_context(%{"$current_url": "https://camelot.test/projects"})

    assert {:ok, task} =
             Ash.create(Task, %{
               title: "Context task",
               project_id: ctx.project.id,
               creator_id: ctx.user.id,
               agent_id: agent!("claude_code").id
             })

    assert %{properties: properties} =
             Enum.find(PostHog.Test.all_captured(), fn event ->
               event.event == "task_created" && event.properties.data_id == task.id
             end)

    assert properties[:"$current_url"] == "https://camelot.test/projects"
  end

  test "explicit event properties take precedence over same-key context", ctx do
    PostHog.set_context(%{data_id: "context-value-should-not-win"})

    assert {:ok, task} =
             Ash.create(Task, %{
               title: "Context collision task",
               project_id: ctx.project.id,
               creator_id: ctx.user.id,
               agent_id: agent!("claude_code").id
             })

    assert %{properties: properties} =
             Enum.find(PostHog.Test.all_captured(), fn event ->
               event.event == "task_created" && event.properties.data_id == task.id
             end)

    assert properties.data_id == task.id
  end

  describe "signup and sign-in" do
    test "a brand new account emits user_signed_up with its auth method" do
      {:ok, user} =
        Ash.create(
          User,
          %{email: "signup-#{System.unique_integer([:positive])}@example.com", role: :user},
          action: :create_user,
          authorize?: false
        )

      assert %{distinct_id: distinct_id, properties: properties} =
               Enum.find(PostHog.Test.all_captured(), &(&1.event == "user_signed_up"))

      assert distinct_id == user.id
      assert properties.auth_method == "invite"
    end

    # Both GitHub and magic-link sign-in run upsert *create* actions,
    # so without the signup window every login would look like a
    # conversion.
    test "a returning account's upsert does not re-emit user_signed_up" do
      old = DateTime.add(DateTime.utc_now(), -3600, :second)
      returning = %User{id: Ash.UUID.generate(), inserted_at: old}

      assert Events.resolve(User, :register_with_github, returning, nil) == :skip
    end

    test "a fresh GitHub registration is reported as such" do
      fresh = %User{id: Ash.UUID.generate(), inserted_at: DateTime.utc_now()}

      assert {:ok, "user_signed_up", %{auth_method: "github"}} =
               Events.resolve(User, :register_with_github, fresh, nil)
    end

    test "user_signed_in sets the person properties funnels filter on", ctx do
      :telemetry.execute([:camelot, :user, :signed_in], %{}, %{
        user: ctx.user,
        auth_method: :magic_link
      })

      assert %{properties: properties} =
               Enum.find(PostHog.Test.all_captured(), &(&1.event == "user_signed_in"))

      assert properties["$set"]["email"] == to_string(ctx.user.email)
      assert properties["$set"]["auth_method"] == "magic_link"
      assert is_boolean(properties["$set"]["is_internal"])
      assert properties["$set_once"]["signed_up_at"]
    end

    test "every capture carries the environment it came from", ctx do
      :telemetry.execute([:camelot, :user, :signed_in], %{}, %{user: ctx.user})

      assert %{properties: properties} =
               Enum.find(PostHog.Test.all_captured(), &(&1.event == "user_signed_in"))

      assert properties.environment == Context.environment()
    end
  end

  describe "onboarding" do
    test "dismissing the guide is captured", ctx do
      {:ok, _user} = Ash.update(ctx.user, %{}, action: :dismiss_onboarding, actor: ctx.user)

      assert %{distinct_id: distinct_id} =
               Enum.find(PostHog.Test.all_captured(), &(&1.event == "onboarding_dismissed"))

      assert distinct_id == ctx.user.id
    end

    test "completing the guide reports how long it took", ctx do
      {:ok, _user} = Ash.update(ctx.user, %{}, action: :complete_onboarding, actor: ctx.user)

      assert %{properties: properties} =
               Enum.find(PostHog.Test.all_captured(), &(&1.event == "onboarding_completed"))

      assert is_integer(properties.duration_since_signup_s)
    end
  end

  describe "credentials" do
    test "adding a Claude key is the funnel's credential step", ctx do
      {:ok, _credential} =
        Ash.create(Credential, %{kind: :claude_api_key, value: "sk-test", user_id: ctx.user.id})

      assert %{distinct_id: distinct_id, properties: properties} =
               Enum.find(PostHog.Test.all_captured(), &(&1.event == "claude_token_added"))

      assert distinct_id == ctx.user.id
      assert properties.kind == "claude_api_key"
      refute Map.has_key?(properties, :value)
    end

    test "another credential kind gets its own, non-Claude event", ctx do
      {:ok, _credential} =
        Ash.create(Credential, %{kind: :openai_api_key, value: "sk-test", user_id: ctx.user.id})

      assert %{properties: properties} =
               Enum.find(PostHog.Test.all_captured(), &(&1.event == "credential_added"))

      assert properties.kind == "openai_api_key"
      refute Enum.any?(PostHog.Test.all_captured(), &(&1.event == "claude_token_added"))
    end

    test "the server-generated SSH key is not a step the user took", ctx do
      {:ok, _credential} =
        Ash.create(Credential, %{
          kind: :ssh_private_key,
          name: "default",
          value: "key",
          metadata: %{"source" => "server_generated"},
          user_id: ctx.user.id
        })

      refute Enum.any?(PostHog.Test.all_captured(), &(&1.event == "credential_added"))
    end

    test "removing a Claude key is captured too", ctx do
      {:ok, credential} =
        Ash.create(Credential, %{kind: :claude_api_key, value: "sk-test", user_id: ctx.user.id})

      :ok = Ash.destroy(credential)

      assert Enum.any?(PostHog.Test.all_captured(), &(&1.event == "claude_token_removed"))
    end
  end

  test "linking a GitHub installation is captured against its user", ctx do
    installation = github_installation!(ctx.user, %{user_id: nil})

    {:ok, _installation} =
      Ash.update(installation, %{user_id: ctx.user.id},
        action: :link_user,
        authorize?: false
      )

    assert %{distinct_id: distinct_id, properties: properties} =
             Enum.find(PostHog.Test.all_captured(), &(&1.event == "github_installation_linked"))

    assert distinct_id == ctx.user.id
    assert properties.installation_id == installation.installation_id
  end

  test "creating an agent CLI is captured", ctx do
    assert {:ok, agent} =
             Ash.create(
               Agent,
               %{
                 slug: "agent-#{System.unique_integer([:positive])}",
                 name: "Test agent",
                 executable: "claude"
               },
               actor: ctx.user
             )

    assert %{distinct_id: distinct_id, properties: properties} =
             Enum.find(PostHog.Test.all_captured(), &(&1.event == "agent_created"))

    assert distinct_id == ctx.user.id
    assert properties.slug == agent.slug
  end

  test "task_errored carries the stage and the bounded reason", ctx do
    {:ok, task} =
      Ash.create(Task, %{
        title: "Failing task",
        project_id: ctx.project.id,
        creator_id: ctx.user.id,
        agent_id: agent!("claude_code").id
      })

    {:ok, _task} =
      Ash.update(task, %{last_error: "[entrypoint] cloning repo\nfatal: Authentication failed"}, action: :mark_error)

    assert %{properties: properties} =
             Enum.find(PostHog.Test.all_captured(), &(&1.event == "task_errored"))

    assert properties.stage == :clone
    assert properties.reason == :git_auth_failed
  end

  test "project_created says whether the creator could actually run it", _ctx do
    actor = user!()

    {:ok, _project} =
      Ash.create(
        Project,
        %{name: "posthog-installations-#{System.unique_integer([:positive])}"},
        actor: actor
      )

    assert %{properties: properties} =
             Enum.find(PostHog.Test.all_captured(), &(&1.event == "project_created"))

    assert properties.has_github_installation == false
    assert properties.has_github_repo == false
  end

  test "a malformed notification is swallowed instead of detaching the handler", _ctx do
    assert :ok ==
             PostHogHandler.handle_event([:camelot, :ash, :notify], %{}, %{}, nil)

    assert :ok ==
             PostHogHandler.handle_event([:camelot, :user, :signed_in], %{}, %{}, nil)
  end
end
