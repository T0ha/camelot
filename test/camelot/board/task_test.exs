defmodule Camelot.Board.TaskTest do
  use Camelot.DataCase, async: true

  alias Camelot.Accounts.User
  alias Camelot.Agents.Agent
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

    {:ok, agent} =
      Ash.create(Agent, %{
        name: "test-agent",
        template_id: agent_template!("claude_code").id,
        project_id: project.id,
        user_id: user.id
      })

    %{project: project, user: user, agent: agent}
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
    test "creates a task with default stage/state", ctx do
      assert {:ok, task} = create_task(ctx.project, ctx.user)
      assert task.title == "Test task"
      assert task.stage == :todo
      assert task.state == :queued
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

  describe "begin_work" do
    test "todo → planning/in_progress", ctx do
      {:ok, task} = create_task(ctx.project, ctx.user)

      assert {:ok, updated} =
               Ash.update(
                 task,
                 %{agent_id: ctx.agent.id},
                 action: :begin_work
               )

      assert updated.stage == :planning
      assert updated.state == :in_progress
    end

    test "planning/queued → planning/in_progress", ctx do
      {:ok, task} = create_task(ctx.project, ctx.user)

      {:ok, task} =
        Ash.update(
          task,
          %{agent_id: ctx.agent.id},
          action: :begin_work
        )

      # Simulate returning to queued after input
      {:ok, task} =
        Ash.update(task, %{}, action: :request_input)

      {:ok, task} =
        Ash.update(task, %{}, action: :provide_input)

      assert task.state == :queued

      assert {:ok, updated} =
               Ash.update(
                 task,
                 %{agent_id: ctx.agent.id},
                 action: :begin_work
               )

      assert updated.stage == :planning
      assert updated.state == :in_progress
    end

    test "fails when not queued", ctx do
      {:ok, task} = create_task(ctx.project, ctx.user)

      {:ok, task} =
        Ash.update(
          task,
          %{agent_id: ctx.agent.id},
          action: :begin_work
        )

      assert task.state == :in_progress

      assert {:error, _} =
               Ash.update(
                 task,
                 %{agent_id: ctx.agent.id},
                 action: :begin_work
               )
    end
  end

  describe "planning flow" do
    test "submit_plan → waiting_for_input", ctx do
      {:ok, task} = create_task(ctx.project, ctx.user)

      {:ok, task} =
        Ash.update(
          task,
          %{agent_id: ctx.agent.id},
          action: :begin_work
        )

      assert {:ok, updated} =
               Ash.update(
                 task,
                 %{plan: "Do X then Y"},
                 action: :submit_plan
               )

      assert updated.stage == :planning
      assert updated.state == :waiting_for_input
      assert updated.plan == "Do X then Y"
    end

    test "approve_plan → executing/queued", ctx do
      {:ok, task} = create_task(ctx.project, ctx.user)

      {:ok, task} =
        Ash.update(
          task,
          %{agent_id: ctx.agent.id},
          action: :begin_work
        )

      {:ok, task} =
        Ash.update(task, %{plan: "plan"}, action: :submit_plan)

      assert {:ok, updated} =
               Ash.update(task, %{}, action: :approve_plan)

      assert updated.stage == :executing
      assert updated.state == :queued
    end

    test "request_plan_changes → planning/queued", ctx do
      {:ok, task} = create_task(ctx.project, ctx.user)

      {:ok, task} =
        Ash.update(
          task,
          %{agent_id: ctx.agent.id},
          action: :begin_work
        )

      {:ok, task} =
        Ash.update(task, %{plan: "plan"}, action: :submit_plan)

      assert {:ok, updated} =
               Ash.update(task, %{}, action: :request_plan_changes)

      assert updated.stage == :planning
      assert updated.state == :queued
    end
  end

  describe "executing flow" do
    setup ctx do
      {:ok, task} = create_task(ctx.project, ctx.user)

      {:ok, task} =
        Ash.update(
          task,
          %{agent_id: ctx.agent.id},
          action: :begin_work
        )

      {:ok, task} =
        Ash.update(task, %{plan: "plan"}, action: :submit_plan)

      {:ok, task} =
        Ash.update(task, %{}, action: :approve_plan)

      # begin_work for executing stage
      {:ok, task} =
        Ash.update(
          task,
          %{agent_id: ctx.agent.id},
          action: :begin_work
        )

      %{task: task}
    end

    test "pr_created → pr/waiting_for_input", ctx do
      assert {:ok, updated} =
               Ash.update(
                 ctx.task,
                 %{
                   pr_url: "https://github.com/o/r/pull/1",
                   pr_number: 1
                 },
                 action: :pr_created
               )

      assert updated.stage == :pr
      assert updated.state == :waiting_for_input
      assert updated.pr_number == 1
    end

    test "request_input → waiting_for_input", ctx do
      assert {:ok, updated} =
               Ash.update(ctx.task, %{}, action: :request_input)

      assert updated.stage == :executing
      assert updated.state == :waiting_for_input
    end
  end

  describe "PR flow" do
    setup ctx do
      {:ok, task} = create_task(ctx.project, ctx.user)

      {:ok, task} =
        Ash.update(
          task,
          %{agent_id: ctx.agent.id},
          action: :begin_work
        )

      {:ok, task} =
        Ash.update(task, %{plan: "p"}, action: :submit_plan)

      {:ok, task} =
        Ash.update(task, %{}, action: :approve_plan)

      {:ok, task} =
        Ash.update(
          task,
          %{agent_id: ctx.agent.id},
          action: :begin_work
        )

      {:ok, task} =
        Ash.update(
          task,
          %{pr_url: "u", pr_number: 1},
          action: :pr_created
        )

      %{task: task}
    end

    test "complete → done/nil", ctx do
      assert {:ok, updated} =
               Ash.update(ctx.task, %{}, action: :complete)

      assert updated.stage == :done
      assert updated.state == nil
    end

    test "request_pr_changes → pr/queued", ctx do
      assert {:ok, updated} =
               Ash.update(
                 ctx.task,
                 %{},
                 action: :request_pr_changes
               )

      assert updated.stage == :pr
      assert updated.state == :queued
    end
  end

  describe "error and retry" do
    test "mark_error and retry", ctx do
      {:ok, task} = create_task(ctx.project, ctx.user)

      {:ok, task} =
        Ash.update(
          task,
          %{agent_id: ctx.agent.id},
          action: :begin_work
        )

      {:ok, task} =
        Ash.update(task, %{}, action: :mark_error)

      assert task.state == :error
      assert task.stage == :planning

      {:ok, task} =
        Ash.update(task, %{}, action: :retry)

      assert task.state == :queued
      assert task.stage == :planning
    end
  end

  describe "cancel" do
    test "cancel from any state", ctx do
      {:ok, task} = create_task(ctx.project, ctx.user)

      assert {:ok, cancelled} =
               Ash.update(task, %{}, action: :cancel)

      assert cancelled.stage == :cancelled
      assert cancelled.state == nil
    end
  end

  describe "reset" do
    test "executing/in_progress → executing/queued", ctx do
      {:ok, task} = create_task(ctx.project, ctx.user)

      {:ok, task} =
        Ash.update(
          task,
          %{agent_id: ctx.agent.id},
          action: :begin_work
        )

      {:ok, task} =
        Ash.update(task, %{plan: "plan"}, action: :submit_plan)

      {:ok, task} = Ash.update(task, %{}, action: :approve_plan)

      {:ok, task} =
        Ash.update(
          task,
          %{agent_id: ctx.agent.id},
          action: :begin_work
        )

      assert task.stage == :executing
      assert task.state == :in_progress

      assert {:ok, reset} = Ash.update(task, %{}, action: :reset)
      assert reset.stage == :executing
      assert reset.state == :queued
    end

    test "todo/queued stays queued", ctx do
      {:ok, task} = create_task(ctx.project, ctx.user)

      assert {:ok, reset} = Ash.update(task, %{}, action: :reset)
      assert reset.stage == :todo
      assert reset.state == :queued
    end

    test "rejects terminal stages", ctx do
      {:ok, task} = create_task(ctx.project, ctx.user)
      {:ok, done} = Ash.update(task, %{}, action: :cancel)

      assert {:error, _} = Ash.update(done, %{}, action: :reset)
    end
  end

  describe "stages/0" do
    test "returns all stages" do
      stages = Task.stages()
      assert :todo in stages
      assert :planning in stages
      assert :executing in stages
      assert :pr in stages
      assert :done in stages
      assert :cancelled in stages
      assert length(stages) == 7
    end
  end

  describe "column_stages/0" do
    test "returns display stages without cancelled" do
      cols = Task.column_stages()
      assert :todo in cols
      assert :done in cols
      refute :cancelled in cols
    end
  end

  describe "runner_handle" do
    setup ctx do
      {:ok, task} = create_task(ctx.project, ctx.user)
      %{task: task}
    end

    test "defaults to nil on create", %{task: task} do
      assert task.runner_handle == nil
    end

    test "set_runner_handle stores the id", %{task: task} do
      assert {:ok, updated} =
               Ash.update(task, %{runner_handle: "abc123"}, action: :set_runner_handle)

      assert updated.runner_handle == "abc123"
    end

    test "set_runner_handle rejects a nil id", %{task: task} do
      assert {:error, _} =
               Ash.update(task, %{runner_handle: nil}, action: :set_runner_handle)
    end

    test "clear_runner_handle resets to nil", %{task: task} do
      {:ok, task} =
        Ash.update(task, %{runner_handle: "abc123"}, action: :set_runner_handle)

      assert {:ok, cleared} = Ash.update(task, %{}, action: :clear_runner_handle)
      assert cleared.runner_handle == nil
    end
  end
end
