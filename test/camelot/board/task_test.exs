defmodule Camelot.Board.TaskTest do
  use Camelot.DataCase, async: true

  alias Camelot.Accounts.User
  alias Camelot.Board.Task
  alias Camelot.Projects.Project

  setup do
    {:ok, project} =
      Ash.create(Project, %{
        name: "test-project",
        path: "/tmp/test-project"
      })

    {:ok, hashed} =
      AshAuthentication.BcryptProvider.hash("Hello world!123")

    user =
      Ash.Seed.seed!(User, %{
        email: "task-test@example.com",
        hashed_password: hashed
      })

    %{project: project, user: user}
  end

  defp create_task(project, user, attrs \\ %{}) do
    defaults = %{
      title: "Test task",
      project_id: project.id,
      creator_id: user.id
    }

    Ash.create(Task, Map.merge(defaults, attrs))
  end

  describe "create" do
    test "creates a task with valid attributes", ctx do
      assert {:ok, task} = create_task(ctx.project, ctx.user)
      assert task.title == "Test task"
      assert task.status == :created
      assert task.priority == 0
    end

    test "fails without title", ctx do
      assert {:error, _} =
               Ash.create(Task, %{
                 project_id: ctx.project.id,
                 creator_id: ctx.user.id
               })
    end

    test "fails without project", ctx do
      assert {:error, _} =
               Ash.create(Task, %{
                 title: "No project",
                 creator_id: ctx.user.id
               })
    end
  end

  describe "state transitions" do
    test "created → planning", ctx do
      {:ok, task} = create_task(ctx.project, ctx.user)

      assert {:ok, updated} =
               Ash.update(task, %{}, action: :start_planning)

      assert updated.status == :planning
    end

    test "planning → plan_review with plan", ctx do
      {:ok, task} = create_task(ctx.project, ctx.user)
      {:ok, task} = Ash.update(task, %{}, action: :start_planning)

      assert {:ok, updated} =
               Ash.update(task, %{plan: "Do X then Y"}, action: :submit_plan)

      assert updated.status == :plan_review
      assert updated.plan == "Do X then Y"
    end

    test "plan_review → executing (approve)", ctx do
      {:ok, task} = create_task(ctx.project, ctx.user)
      {:ok, task} = Ash.update(task, %{}, action: :start_planning)

      {:ok, task} =
        Ash.update(task, %{plan: "plan"}, action: :submit_plan)

      assert {:ok, updated} =
               Ash.update(task, %{}, action: :approve_plan)

      assert updated.status == :executing
    end

    test "plan_review → planning (reject)", ctx do
      {:ok, task} = create_task(ctx.project, ctx.user)
      {:ok, task} = Ash.update(task, %{}, action: :start_planning)

      {:ok, task} =
        Ash.update(task, %{plan: "plan"}, action: :submit_plan)

      assert {:ok, updated} =
               Ash.update(task, %{}, action: :reject_plan)

      assert updated.status == :planning
    end

    test "executing → pr_created", ctx do
      {:ok, task} = create_task(ctx.project, ctx.user)
      {:ok, task} = Ash.update(task, %{}, action: :start_planning)

      {:ok, task} =
        Ash.update(task, %{plan: "plan"}, action: :submit_plan)

      {:ok, task} = Ash.update(task, %{}, action: :approve_plan)

      assert {:ok, updated} =
               Ash.update(
                 task,
                 %{
                   pr_url: "https://github.com/o/r/pull/1",
                   pr_number: 1
                 },
                 action: :pr_created
               )

      assert updated.status == :pr_created
      assert updated.pr_number == 1
    end

    test "pr_review → done (approve_pr)", ctx do
      {:ok, task} = create_task(ctx.project, ctx.user)
      {:ok, task} = Ash.update(task, %{}, action: :start_planning)

      {:ok, task} =
        Ash.update(task, %{plan: "p"}, action: :submit_plan)

      {:ok, task} = Ash.update(task, %{}, action: :approve_plan)

      {:ok, task} =
        Ash.update(task, %{pr_url: "u", pr_number: 1}, action: :pr_created)

      {:ok, task} =
        Ash.update(task, %{}, action: :submit_pr_review)

      assert {:ok, updated} =
               Ash.update(task, %{}, action: :approve_pr)

      assert updated.status == :done
    end

    test "pr_review → pr_fix (request changes)", ctx do
      {:ok, task} = create_task(ctx.project, ctx.user)
      {:ok, task} = Ash.update(task, %{}, action: :start_planning)

      {:ok, task} =
        Ash.update(task, %{plan: "p"}, action: :submit_plan)

      {:ok, task} = Ash.update(task, %{}, action: :approve_plan)

      {:ok, task} =
        Ash.update(task, %{pr_url: "u", pr_number: 1}, action: :pr_created)

      {:ok, task} =
        Ash.update(task, %{}, action: :submit_pr_review)

      assert {:ok, updated} =
               Ash.update(task, %{}, action: :request_pr_changes)

      assert updated.status == :pr_fix
    end

    test "pr_fix → executing", ctx do
      {:ok, task} = create_task(ctx.project, ctx.user)
      {:ok, task} = Ash.update(task, %{}, action: :start_planning)

      {:ok, task} =
        Ash.update(task, %{plan: "p"}, action: :submit_plan)

      {:ok, task} = Ash.update(task, %{}, action: :approve_plan)

      {:ok, task} =
        Ash.update(task, %{pr_url: "u", pr_number: 1}, action: :pr_created)

      {:ok, task} =
        Ash.update(task, %{}, action: :submit_pr_review)

      {:ok, task} =
        Ash.update(task, %{}, action: :request_pr_changes)

      assert {:ok, updated} =
               Ash.update(task, %{}, action: :start_pr_fix)

      assert updated.status == :executing
    end

    test "invalid transition fails", ctx do
      {:ok, task} = create_task(ctx.project, ctx.user)

      assert {:error, _} =
               Ash.update(task, %{}, action: :approve_plan)
    end

    test "cancel from any non-terminal state", ctx do
      {:ok, task} = create_task(ctx.project, ctx.user)

      assert {:ok, cancelled} =
               Ash.update(task, %{}, action: :cancel)

      assert cancelled.status == :cancelled
    end
  end

  describe "statuses/0" do
    test "returns all statuses" do
      statuses = Task.statuses()
      assert :created in statuses
      assert :done in statuses
      assert :cancelled in statuses
      assert length(statuses) == 9
    end
  end

  describe "column_statuses/0" do
    test "returns display statuses without cancelled" do
      cols = Task.column_statuses()
      assert :created in cols
      assert :done in cols
      refute :cancelled in cols
    end
  end
end
