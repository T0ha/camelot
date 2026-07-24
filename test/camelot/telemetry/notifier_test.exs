defmodule Camelot.Telemetry.NotifierTest do
  use Camelot.DataCase, async: true

  alias Camelot.Agents.Agent
  alias Camelot.Board.Task
  alias Camelot.Projects.Project

  setup do
    {:ok, project} =
      Ash.create(Project, %{
        name: "notifier-test-#{System.unique_integer([:positive])}",
        path: "/tmp/notifier-test"
      })

    user = user!()

    ref = :telemetry_test.attach_event_handlers(self(), [[:camelot, :ash, :notify]])
    on_exit(fn -> :telemetry.detach(ref) end)

    %{ref: ref, project: project, user: user}
  end

  test "emits [:camelot, :ash, :notify] when a project is created", ctx do
    assert {:ok, project} =
             Ash.create(Project, %{name: "notifier-test-other-#{System.unique_integer([:positive])}"})

    project_id = project.id

    assert_received {[:camelot, :ash, :notify], ref, %{}, %{resource: Project, data: %{id: ^project_id}} = metadata}

    assert ref == ctx.ref
    assert metadata.action.name == :create
    assert metadata.actor == nil
  end

  test "emits [:camelot, :ash, :notify] when an agent is created", ctx do
    assert {:ok, agent} =
             Ash.create(Agent, %{
               name: "notifier-test-agent",
               template_id: agent_template!("claude_code").id,
               project_id: ctx.project.id,
               user_id: ctx.user.id
             })

    agent_id = agent.id

    assert_received {[:camelot, :ash, :notify], _ref, %{}, %{resource: Agent, data: %{id: ^agent_id}} = metadata}

    assert metadata.action.name == :create
  end

  test "emits [:camelot, :ash, :notify] when a task is created", ctx do
    assert {:ok, task} =
             Ash.create(Task, %{
               title: "Notifier task",
               project_id: ctx.project.id,
               creator_id: ctx.user.id
             })

    task_id = task.id

    assert_received {[:camelot, :ash, :notify], _ref, %{}, %{resource: Task, data: %{id: ^task_id}} = metadata}

    assert metadata.action.name == :create
  end

  test "emits [:camelot, :ash, :notify] with the actor when one is present", ctx do
    assert {:ok, project} =
             Ash.create(
               Project,
               %{name: "notifier-test-actor-#{System.unique_integer([:positive])}"},
               actor: ctx.user
             )

    project_id = project.id

    assert_received {[:camelot, :ash, :notify], _ref, %{}, %{resource: Project, data: %{id: ^project_id}} = metadata}

    assert metadata.actor.id == ctx.user.id
  end

  test "emits [:camelot, :ash, :notify] on task updates too, since the notifier is dumb", ctx do
    {:ok, task} =
      Ash.create(Task, %{
        title: "Notifier update task",
        project_id: ctx.project.id,
        creator_id: ctx.user.id
      })

    task_id = task.id

    assert_received {[:camelot, :ash, :notify], _ref, %{},
                     %{resource: Task, data: %{id: ^task_id}, action: %{name: :create}}}

    assert {:ok, _task} = Ash.update(task, %{title: "Renamed"})

    assert_received {[:camelot, :ash, :notify], _ref, %{},
                     %{resource: Task, data: %{id: ^task_id}, action: %{name: :update}}}
  end
end
