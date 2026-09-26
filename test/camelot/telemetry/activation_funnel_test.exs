defmodule Camelot.Telemetry.ActivationFunnelTest do
  @moduledoc """
  The funnel GH#168 exists to make buildable, asserted end to end.

  Every step already has a test of its own, and
  `Camelot.Telemetry.EventsTest` guards the catalogue those tests read
  from. Neither sees the property a funnel actually needs: that one
  account's journey emits these six events, in this order, **on one
  person**. A funnel step whose `distinct_id` resolves differently
  from its neighbours' is not a step at all — PostHog simply stops
  counting there — and that is a per-resource decision
  (`PostHogHandler.distinct_id/2`) no single-event test can see.
  """
  use Camelot.DataCase, async: true

  alias Camelot.Accounts.Credential
  alias Camelot.Accounts.User
  alias Camelot.Board.Task
  alias Camelot.Github.UserInstallations
  alias Camelot.Projects.Project
  alias Camelot.Telemetry.Context

  # Verbatim from the issue's first acceptance criterion.
  @funnel [
    "user_signed_up",
    "github_setup_succeeded",
    "claude_token_added",
    "project_created",
    "task_created",
    "task_pr_created"
  ]

  describe "the activation funnel" do
    test "one account's journey emits every step, in order" do
      walk_the_funnel()

      assert funnel_events() == @funnel
    end

    test "every step lands on the same person" do
      user = walk_the_funnel()

      for event <- captured(), event.event in @funnel do
        assert event.distinct_id == user.id,
               "#{event.event} was attributed to #{inspect(event.distinct_id)}, " <>
                 "not to the account that walked the funnel"
      end
    end

    # `environment = production` is the other half of the criterion:
    # both clusters report into one PostHog project, so a capture
    # without it cannot be excluded from — or counted into — anything.
    test "every capture along the way carries the environment" do
      walk_the_funnel()

      for event <- captured() do
        assert event.properties[:environment] == Context.environment(),
               "#{event.event} carries no environment property"
      end
    end

    # The funnel is filtered by `is_internal = false`, which is a
    # *person* property: it has to arrive on the same person the
    # events above do, or the filter drops the whole journey.
    test "the person the journey belongs to is marked internal or not" do
      user = walk_the_funnel()

      :telemetry.execute([:camelot, :user, :signed_in], %{}, %{
        user: user,
        auth_method: :github
      })

      assert %{distinct_id: distinct_id, properties: properties} =
               Enum.find(captured(), &(&1.event == "user_signed_in"))

      assert distinct_id == user.id
      assert is_boolean(properties["$set"]["is_internal"])
      assert properties["$set"]["is_internal"] == Context.internal?(user)
      assert properties["$set_once"]["signed_up_at"] == DateTime.to_iso8601(user.inserted_at)
    end
  end

  # Drives each step through the same code path the product does, in
  # the order a real account takes them.
  @spec walk_the_funnel() :: User.t()
  defp walk_the_funnel do
    user = register!()

    connect_github!(user)
    add_claude_key!(user)

    project = create_project!(user)

    user
    |> create_task!(project)
    |> open_pr!()

    user
  end

  # The real `:register_with_github` upsert, the way
  # AshAuthentication runs it: identity comes from `user_info`, so
  # there is no HTTP and no GitHub credentials involved.
  defp register! do
    {:ok, user} =
      User
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_context(%{private: %{ash_authentication?: true}})
      |> Ash.Changeset.for_create(
        :register_with_github,
        %{
          user_info: %{
            "sub" => System.unique_integer([:positive]),
            "email" => "funnel-#{System.unique_integer([:positive])}@example.com",
            "email_verified" => true,
            "preferred_username" => "octocat"
          },
          oauth_tokens: %{"access_token" => "gho_faketoken"}
        },
        upsert?: true,
        upsert_identity: :unique_email
      )
      |> Ash.create()

    user
  end

  # The GitHub login sync, which is the intended connect path: the
  # install is folded into the login round-trip.
  defp connect_github!(user) do
    :ok =
      UserInstallations.link(
        [
          %{
            "id" => System.unique_integer([:positive]),
            "account" => %{"login" => "octocat", "type" => "User"},
            "repository_selection" => "all"
          }
        ],
        user
      )
  end

  defp add_claude_key!(user) do
    {:ok, _credential} =
      Ash.create(Credential, %{kind: :claude_api_key, value: "sk-test", user_id: user.id})
  end

  defp create_project!(user) do
    {:ok, project} =
      Ash.create(
        Project,
        %{name: "funnel-#{System.unique_integer([:positive])}"},
        actor: user
      )

    project
  end

  defp create_task!(user, project) do
    {:ok, task} =
      Ash.create(Task, %{
        title: "Funnel task",
        project_id: project.id,
        creator_id: user.id,
        agent_id: agent!("claude_code").id
      })

    task
  end

  # `:pr_created` only accepts a task that is executing and in
  # progress, so the run is driven through the stages the runner
  # drives it through rather than seeded into place.
  defp open_pr!(task) do
    {:ok, task} = Ash.update(task, %{}, action: :begin_work)
    {:ok, task} = Ash.update(task, %{plan: "plan"}, action: :submit_plan)
    {:ok, task} = Ash.update(task, %{}, action: :approve_plan)
    {:ok, task} = Ash.update(task, %{}, action: :begin_work)

    {:ok, task} =
      Ash.update(
        task,
        %{pr_url: "https://github.com/octocat/repo/pull/1", pr_number: 1},
        action: :pr_created
      )

    task
  end

  # Captures arrive newest-first, and this case is `async: true`, so
  # the stash holds this journey and nothing else.
  defp captured, do: Enum.reverse(PostHog.Test.all_captured())

  defp funnel_events do
    for event <- captured(), event.event in @funnel, do: event.event
  end
end
