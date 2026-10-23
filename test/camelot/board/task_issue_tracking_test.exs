defmodule Camelot.Board.TaskIssueTrackingTest do
  use Camelot.DataCase, async: true

  alias Camelot.Board.Task
  alias Camelot.Board.Workers.PostToIssue
  alias Camelot.Projects.Project

  setup do
    user = user!()

    project =
      Ash.create!(Project, %{name: "issue-tracking-#{System.unique_integer([:positive])}", path: "/tmp/it"})

    %{project: project, user: user}
  end

  defp create_task(ctx, attrs \\ %{}) do
    defaults = %{
      title: "Issue task",
      description: "Do the thing exactly like this.",
      project_id: ctx.project.id,
      creator_id: ctx.user.id,
      agent_id: agent!("claude_code").id
    }

    Ash.create(Task, Map.merge(defaults, attrs))
  end

  defp seed_task(ctx, attrs) do
    defaults = %{
      title: "Seeded",
      project_id: ctx.project.id,
      creator_id: ctx.user.id,
      agent_id: agent!("claude_code").id
    }

    Ash.Seed.seed!(Task, Map.merge(defaults, attrs))
  end

  describe ":create with issue tracking" do
    test "persists the issue number", ctx do
      assert {:ok, task} = create_task(ctx, %{issue_number: 7})
      assert task.issue_number == 7
    end

    test "starts in todo/queued by default", ctx do
      assert {:ok, task} = create_task(ctx)
      assert task.stage == :todo
      assert task.state == :queued
      assert is_nil(task.plan)
    end

    test "skip_planning starts in executing with the description as plan", ctx do
      assert {:ok, task} = create_task(ctx, %{skip_planning: true})

      assert task.stage == :executing
      assert task.state == :queued
      assert task.plan == "Do the thing exactly like this."
    end

    test "skip_planning false behaves like the default", ctx do
      assert {:ok, task} = create_task(ctx, %{skip_planning: false})
      assert task.stage == :todo
    end

    test "skip_planning requires a description to use as the plan", ctx do
      assert {:error, error} = create_task(ctx, %{skip_planning: true, description: nil})
      assert Enum.any?(error.errors, &(&1.field == :description))
    end
  end

  describe ":submit_plan" do
    test "forgets the previous plan comment so a stale 👍 cannot approve", ctx do
      task = seed_task(ctx, %{stage: :planning, state: :in_progress, plan_comment_id: 55})

      assert {:ok, updated} = Ash.update(task, %{plan: "New plan"}, action: :submit_plan)
      assert is_nil(updated.plan_comment_id)
    end

    test "queues the plan to be posted on the issue", ctx do
      task = seed_task(ctx, %{stage: :planning, state: :in_progress, issue_number: 9})

      assert {:ok, _} = Ash.update(task, %{plan: "New plan"}, action: :submit_plan)
      assert_enqueued(worker: PostToIssue, args: %{task_id: task.id, kind: "plan"})
    end

    test "queues nothing for a task without an issue", ctx do
      task = seed_task(ctx, %{stage: :planning, state: :in_progress})

      assert {:ok, _} = Ash.update(task, %{plan: "New plan"}, action: :submit_plan)
      refute_enqueued(worker: PostToIssue)
    end
  end

  describe ":approve_plan" do
    test "queues the approved-in-Camelot comment for an issue task", ctx do
      task = seed_task(ctx, %{stage: :planning, state: :waiting_for_input, plan: "P", issue_number: 9})

      assert {:ok, _} = Ash.update(task, %{}, action: :approve_plan)
      assert_enqueued(worker: PostToIssue, args: %{task_id: task.id, kind: "approved_in_camelot"})
    end
  end

  describe ":approve_plan_from_github" do
    test "starts execution without commenting back", ctx do
      task = seed_task(ctx, %{stage: :planning, state: :waiting_for_input, plan: "P", issue_number: 9})

      assert {:ok, updated} = Ash.update(task, %{}, action: :approve_plan_from_github)
      assert updated.stage == :executing
      assert updated.state == :queued
      refute_enqueued(worker: PostToIssue)
    end
  end

  describe ":record_plan_comment" do
    test "stores the plan comment id", ctx do
      task = seed_task(ctx, %{stage: :planning, state: :waiting_for_input, plan: "P"})

      assert {:ok, updated} = Ash.update(task, %{plan_comment_id: 77}, action: :record_plan_comment)
      assert updated.plan_comment_id == 77
    end
  end
end
