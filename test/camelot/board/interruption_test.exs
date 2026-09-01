defmodule Camelot.Board.InterruptionTest do
  use Camelot.DataCase, async: false

  alias Camelot.Board.Interruption
  alias Camelot.Board.Task
  alias Camelot.Projects.Project

  setup do
    {:ok, project} =
      Ash.create(Project, %{name: "interruption-project", path: "/tmp/interruption"})

    %{project: project, user: user!()}
  end

  defp create_task(ctx, attrs \\ %{}) do
    {:ok, task} =
      Ash.create(
        Task,
        Map.merge(
          %{
            title: "Interrupted task",
            project_id: ctx.project.id,
            creator_id: ctx.user.id,
            agent_id: agent!("claude_code").id
          },
          attrs
        )
      )

    task
  end

  defp with_max_requeues(max, fun) do
    runner = Application.get_env(:camelot, :runner, [])
    Application.put_env(:camelot, :runner, Keyword.put(runner, :max_interrupt_requeues, max))

    try do
      fun.()
    after
      Application.put_env(:camelot, :runner, runner)
    end
  end

  describe "requeue_or_error/2" do
    test "re-queues an interrupted run instead of erroring it", ctx do
      task = create_task(ctx)
      {:ok, task} = Ash.update(task, %{}, action: :begin_work)
      {:ok, task} = Ash.update(task, %{runner_handle: "svc-1"}, action: :set_runner_handle)

      assert {:ok, requeued} =
               Interruption.requeue_or_error(task, "runner container replaced by a deploy")

      assert requeued.state == :queued
      assert requeued.stage == :planning
      assert requeued.runner_handle == nil
      assert requeued.interrupt_requeues == 1
    end

    test "errors the task once the re-queue cap is reached", ctx do
      with_max_requeues(2, fn ->
        task = create_task(ctx)
        {:ok, task} = Interruption.requeue_or_error(task, "boom")
        {:ok, task} = Interruption.requeue_or_error(task, "boom")

        assert task.interrupt_requeues == 2

        assert {:ok, errored} = Interruption.requeue_or_error(task, "boom again")

        assert errored.state == :error
        assert errored.last_error =~ "Re-queued 2 times"
        assert errored.last_error =~ "boom again"
      end)
    end

    test "leaves a cancelled task alone", ctx do
      task = create_task(ctx)
      {:ok, task} = Ash.update(task, %{}, action: :cancel)

      assert {:error, _} = Interruption.requeue_or_error(task, "runner lost")

      assert Ash.get!(Task, task.id).stage == :cancelled
    end

    test "broadcasts the update to the task and board topics", ctx do
      task = create_task(ctx)
      Phoenix.PubSub.subscribe(Camelot.PubSub, "task:#{task.id}")

      {:ok, _} = Interruption.requeue_or_error(task, "runner lost")

      assert_receive {:task_updated, %Task{state: :queued}}
    end
  end

  describe "requeue_or_error_by_id/2" do
    test "looks the task up", ctx do
      task = create_task(ctx)

      assert {:ok, requeued} = Interruption.requeue_or_error_by_id(task.id, "runner lost")
      assert requeued.interrupt_requeues == 1
    end

    test "returns :not_found for an unknown id" do
      assert {:error, :not_found} =
               Interruption.requeue_or_error_by_id(Ash.UUID.generate(), "runner lost")
    end
  end
end
