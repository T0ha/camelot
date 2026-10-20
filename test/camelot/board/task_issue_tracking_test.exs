defmodule Camelot.Board.TaskIssueTrackingTest do
  use Camelot.DataCase, async: true

  alias Camelot.Board.Task
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
end
