defmodule Camelot.Telemetry.PostHogHandlerTest do
  use Camelot.DataCase, async: true

  alias Ash.Resource.Info
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

  # `PostHog.Context` only ever merges and offers no delete, so a
  # property written process-wide rides along on every later capture
  # from the same LiveView process. Event-scoped context is how the
  # onboarding guide hands `steps_done` to a notifier-driven capture
  # without stamping it on everything that follows.
  test "event-scoped context reaches its own event and no other", ctx do
    PostHog.set_event_context("task_created", %{via: "scoped"})

    assert {:ok, task} =
             Ash.create(Task, %{
               title: "Scoped context task",
               project_id: ctx.project.id,
               creator_id: ctx.user.id,
               agent_id: agent!("claude_code").id
             })

    assert {:ok, _project} =
             Ash.create(
               Project,
               %{
                 name: "scoped-#{System.unique_integer([:positive])}",
                 path: "/tmp/scoped"
               },
               actor: ctx.user
             )

    assert %{properties: %{via: "scoped"}} =
             Enum.find(PostHog.Test.all_captured(), fn event ->
               event.event == "task_created" && event.properties.data_id == task.id
             end)

    refute Enum.any?(PostHog.Test.all_captured(), fn event ->
             event.event == "project_created" && Map.has_key?(event.properties, :via)
           end)
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

    # Both real `:create_user` call sites pass the *inviter* as the
    # actor: the admin screen (`CamelotWeb.AdminLive.Users`) and a
    # project invite
    # (`Camelot.Projects.Membership.Changes.ResolveInvitee`).
    # Crediting the invitee's signup to them would drop the invited
    # account out of the funnel's first step for good — a returning
    # login is an upsert and never re-emits it — while counting the
    # inviter as signing up once per invite.
    test "an invited account's signup is attributed to the invitee" do
      inviter = user!(%{role: :admin})

      {:ok, invitee} =
        Ash.create(
          User,
          %{
            email: "invited-#{System.unique_integer([:positive])}@example.com",
            role: :user
          },
          action: :create_user,
          actor: inviter
        )

      assert [%{distinct_id: distinct_id}] = signups_for(invitee.id)
      assert distinct_id == invitee.id
      assert signups_for(inviter.id) == []
    end

    # Both GitHub and magic-link sign-in run upsert *create* actions,
    # so without the signup window every login would look like a
    # conversion.
    test "a returning account's upsert does not re-emit user_signed_up" do
      old = DateTime.add(DateTime.utc_now(), -3600, :second)
      returning = %User{id: Ash.UUID.generate(), inserted_at: old}

      assert Events.resolve(User, :register_with_github, returning, nil) == :skip
    end

    # `new_user?/1` reads `inserted_at` because Ash exposes no
    # insert-vs-conflict flag, and that only tells the truth while
    # neither upsert replaces the column on conflict. The magic-link
    # action is *generated* by AshAuthentication, so nothing in this
    # repo pins its `upsert_fields`: were an upgrade to widen them,
    # `user_signed_up` would fire on every login, the funnel's first
    # step would silently become a copy of `user_signed_in`, and every
    # conversion rate measured off it would be wrong.
    test "neither upsert action replaces inserted_at on conflict" do
      for action <- [:register_with_github, :sign_in_with_magic_link] do
        upsert_fields = Info.action(User, action).upsert_fields

        assert is_list(upsert_fields), "#{action} is no longer an upsert"
        refute :inserted_at in upsert_fields
      end
    end

    # The test above asserts the classifier; this one asserts its
    # premise, by running the upsert a returning user actually runs.
    # `GateGithubRegistration` lets an existing account through
    # whatever `:registration_enabled` says, so this needs no
    # application env mutation and stays async-safe.
    test "a real returning GitHub login keeps its signup time and stays silent" do
      signed_up_at = DateTime.add(DateTime.utc_now(), -30, :day)
      existing = user!(%{confirmed_at: signed_up_at, inserted_at: signed_up_at})

      assert {:ok, user} = register_with_github(to_string(existing.email))

      assert user.id == existing.id
      assert DateTime.compare(user.inserted_at, signed_up_at) == :eq
      assert signups_for(user.id) == []
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

    test "removing another credential kind keeps its own, non-Claude event", ctx do
      {:ok, credential} =
        Ash.create(Credential, %{kind: :openai_api_key, value: "sk-test", user_id: ctx.user.id})

      :ok = Ash.destroy(credential)

      assert %{distinct_id: distinct_id, properties: properties} =
               Enum.find(PostHog.Test.all_captured(), &(&1.event == "credential_removed"))

      assert distinct_id == ctx.user.id
      assert properties.kind == "openai_api_key"
      refute Enum.any?(PostHog.Test.all_captured(), &(&1.event == "claude_token_removed"))
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

  # Suspension arrives from a GitHub webhook, so there is no actor at
  # all — the capture has to fall back to the installation's own
  # `user_id` or the account silently drops out of the funnel.
  test "suspending and unsuspending an installation is captured against its user", ctx do
    installation = github_installation!(ctx.user)

    {:ok, suspended} = Ash.update(installation, %{}, action: :suspend, authorize?: false)
    {:ok, _installation} = Ash.update(suspended, %{}, action: :unsuspend, authorize?: false)

    for event_name <- ["github_installation_suspended", "github_installation_unsuspended"] do
      assert %{distinct_id: distinct_id, properties: properties} =
               Enum.find(PostHog.Test.all_captured(), &(&1.event == event_name))

      assert distinct_id == ctx.user.id
      assert properties.installation_id == installation.installation_id
    end
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

  test "editing an agent CLI is captured separately from creating one", ctx do
    {:ok, agent} =
      Ash.create(
        Agent,
        %{
          slug: "agent-#{System.unique_integer([:positive])}",
          name: "Test agent",
          executable: "claude"
        },
        actor: ctx.user
      )

    assert {:ok, _agent} =
             Ash.update(agent, %{name: "Renamed agent"}, action: :update, actor: ctx.user)

    assert %{distinct_id: distinct_id, properties: properties} =
             Enum.find(PostHog.Test.all_captured(), &(&1.event == "agent_updated"))

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

  # A lost runner is infrastructure, not the agent, and used to be
  # indistinguishable from `task_errored` — it gets its own event so
  # the two failure populations can be counted apart.
  test "task_runner_lost is its own event and carries the same bounded pair", ctx do
    {:ok, task} =
      Ash.create(Task, %{
        title: "Lost runner",
        project_id: ctx.project.id,
        creator_id: ctx.user.id,
        agent_id: agent!("claude_code").id
      })

    {:ok, _task} =
      Ash.update(task, %{last_error: "Swarm could not provision a node for this task"}, action: :mark_runner_lost)

    assert %{distinct_id: distinct_id, properties: properties} =
             Enum.find(PostHog.Test.all_captured(), &(&1.event == "task_runner_lost"))

    assert distinct_id == ctx.user.id
    assert properties.stage == :boot
    assert properties.reason == :provision_failed
    refute Enum.any?(PostHog.Test.all_captured(), &(&1.event == "task_errored"))
  end

  # `has_github_installation` is what separates "made a project" from
  # "made a project that can actually run", so it has to be pinned
  # from both ends: a property that is always false measures nothing,
  # and one that is true whenever *anybody* has connected the App
  # would report the whole cohort as equipped.
  describe "project_created's has_github_installation" do
    test "is false when the creator has connected nothing", _ctx do
      actor = user!()

      create_project!(actor)

      assert project_created_properties().has_github_installation == false
      assert project_created_properties().has_github_repo == false
    end

    test "is true when the creator has a live installation", _ctx do
      actor = user!()
      github_installation!(actor)

      create_project!(actor)

      assert project_created_properties().has_github_installation == true
    end

    test "is false when the only installation is another user's", _ctx do
      actor = user!()
      github_installation!(user!())

      create_project!(actor)

      assert project_created_properties().has_github_installation == false
    end

    test "is false when the creator's installation is suspended", _ctx do
      actor = user!()
      github_installation!(actor, %{suspended_at: DateTime.utc_now()})

      create_project!(actor)

      assert project_created_properties().has_github_installation == false
    end
  end

  test "a malformed notification is swallowed instead of detaching the handler", _ctx do
    assert :ok ==
             PostHogHandler.handle_event([:camelot, :ash, :notify], %{}, %{}, nil)

    assert :ok ==
             PostHogHandler.handle_event([:camelot, :user, :signed_in], %{}, %{}, nil)
  end

  # Drives the real `:register_with_github` upsert the way
  # AshAuthentication does, so the returning-login test exercises the
  # action rather than a hand-built struct. No GitHub credentials and
  # no HTTP: the action resolves identity from `user_info` alone.
  defp register_with_github(email) do
    User
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_context(%{private: %{ash_authentication?: true}})
    |> Ash.Changeset.for_create(
      :register_with_github,
      %{
        user_info: %{
          "sub" => System.unique_integer([:positive]),
          "email" => email,
          "email_verified" => true,
          "preferred_username" => "octocat"
        },
        oauth_tokens: %{"access_token" => "gho_faketoken"}
      },
      upsert?: true,
      upsert_identity: :unique_email
    )
    |> Ash.create()
  end

  defp signups_for(user_id) do
    Enum.filter(
      PostHog.Test.all_captured(),
      &(&1.event == "user_signed_up" and &1.distinct_id == user_id)
    )
  end

  defp create_project!(actor) do
    {:ok, project} =
      Ash.create(
        Project,
        %{name: "posthog-installations-#{System.unique_integer([:positive])}"},
        actor: actor
      )

    project
  end

  defp project_created_properties do
    assert %{properties: properties} =
             Enum.find(PostHog.Test.all_captured(), &(&1.event == "project_created"))

    properties
  end
end
