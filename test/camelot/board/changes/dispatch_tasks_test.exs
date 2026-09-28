defmodule Camelot.Board.Changes.DispatchTasksTest do
  use Camelot.DataCase, async: false

  alias Camelot.Accounts.User
  alias Camelot.Board.Task
  alias Camelot.Board.TaskLink
  alias Camelot.Projects.Project

  setup do
    {:ok, project} =
      Ash.create(Project, %{
        name: "dispatch-proj-#{System.unique_integer()}",
        path: "/tmp/dispatch-proj-#{System.unique_integer()}"
      })

    {:ok, hashed} = AshAuthentication.BcryptProvider.hash("Hello world!123")

    user =
      Ash.Seed.seed!(User, %{
        email: "dispatch-#{System.unique_integer()}@example.com",
        hashed_password: hashed
      })

    %{project: project, user: user}
  end

  defp create_task(ctx, attrs \\ %{}) do
    defaults = %{
      title: "task-#{System.unique_integer([:positive])}",
      project_id: ctx.project.id,
      creator_id: ctx.user.id,
      agent_id: agent!("claude_code").id
    }

    {:ok, task} = Ash.create(Task, Map.merge(defaults, attrs))
    task
  end

  defp dispatch! do
    Task
    |> Ash.ActionInput.for_action(:dispatch_tasks, %{})
    |> Ash.run_action!()
  end

  test "a task blocked by a pre-pr blocker is skipped", ctx do
    blocker = create_task(ctx)
    dependent = create_task(ctx)

    {:ok, _link} =
      Ash.create(TaskLink, %{
        source_task_id: blocker.id,
        target_task_id: dependent.id,
        link_type: :blocks
      })

    dispatch!()

    reloaded = Ash.get!(Task, dependent.id)
    assert reloaded.state == :queued
    assert reloaded.stage == :todo
  end

  test "the dependent dispatches once the blocker reaches :pr", ctx do
    blocker = create_task(ctx)
    dependent = create_task(ctx)

    {:ok, _link} =
      Ash.create(TaskLink, %{
        source_task_id: blocker.id,
        target_task_id: dependent.id,
        link_type: :blocks
      })

    dispatch!()
    assert Ash.get!(Task, dependent.id).state == :queued

    Ash.Seed.update!(blocker, %{stage: :pr})

    dispatch!()
    assert Ash.get!(Task, dependent.id).state == :in_progress
  end

  test "an unlinked task dispatches normally", ctx do
    task = create_task(ctx)

    dispatch!()

    assert Ash.get!(Task, task.id).state == :in_progress
  end

  test "a task blocked by a pre-pr subtask is skipped", ctx do
    parent = create_task(ctx)
    subtask = create_task(ctx)

    {:ok, _link} =
      Ash.create(TaskLink, %{
        source_task_id: parent.id,
        target_task_id: subtask.id,
        link_type: :parent_of
      })

    dispatch!()

    assert Ash.get!(Task, parent.id).state == :queued
  end

  test "a task in an archived project is skipped", ctx do
    # Archiving a project has to stop its agents; otherwise the
    # every-minute dispatcher keeps burning runner slots on a board
    # that has been retired.
    task = create_task(ctx)
    {:ok, _project} = Ash.update(ctx.project, %{}, action: :archive)

    dispatch!()

    assert Ash.get!(Task, task.id).state == :queued
  end
end
