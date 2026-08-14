defmodule Camelot.Telemetry.PostHogHandlerTest do
  use Camelot.DataCase, async: true

  alias Camelot.Board.Task
  alias Camelot.Projects.Project

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
end
