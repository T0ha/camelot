defmodule Camelot.Board.TaskScheduleTest do
  use Camelot.DataCase, async: true

  alias Camelot.Board.Task
  alias Camelot.Projects.Project

  setup do
    {:ok, project} =
      Ash.create(Project, %{
        name: "sched-#{System.unique_integer([:positive])}",
        path: "/tmp/sched-#{System.unique_integer([:positive])}"
      })

    %{project: project, user: user!()}
  end

  defp create(ctx, attrs \\ %{}) do
    Ash.create(
      Task,
      Map.merge(
        %{
          title: "scheduled",
          project_id: ctx.project.id,
          creator_id: ctx.user.id,
          agent_id: agent!("claude_code").id
        },
        attrs
      )
    )
  end

  defp later(seconds), do: DateTime.add(DateTime.utc_now(), seconds, :second)

  test "new tasks inherit everything", ctx do
    {:ok, task} = create(ctx)

    assert task.weekly_cap_override == nil
    assert task.windows_override == nil
    assert task.ignore_limits == false
    assert task.start_at == nil
    assert task.deadline_at == nil
  end

  test ":create accepts the schedule fields", ctx do
    start_at = later(3600)
    deadline_at = later(7200)

    {:ok, task} = create(ctx, %{start_at: start_at, deadline_at: deadline_at})

    assert DateTime.compare(task.start_at, start_at) == :eq
    assert DateTime.compare(task.deadline_at, deadline_at) == :eq
  end

  test "the deadline must come after the start", ctx do
    assert {:error, _} = create(ctx, %{start_at: later(7200), deadline_at: later(3600)})
  end

  describe ":set_schedule" do
    test "sets the overrides", ctx do
      {:ok, task} = create(ctx)

      {:ok, task} =
        Ash.update(
          task,
          %{weekly_cap_override: 90, windows_override: [%{start_minute: 0, end_minute: 600}]},
          action: :set_schedule
        )

      assert task.weekly_cap_override == 90
      assert [%{start_minute: 0, end_minute: 600}] = task.windows_override
      assert task.ignore_limits == false
    end

    test "pinning a start or deadline implies ignore_limits", ctx do
      {:ok, task} = create(ctx)

      {:ok, pinned} = Ash.update(task, %{start_at: later(60)}, action: :set_schedule)
      assert pinned.ignore_limits == true

      {:ok, other} = create(ctx)
      {:ok, pinned} = Ash.update(other, %{deadline_at: later(60)}, action: :set_schedule)
      assert pinned.ignore_limits == true
    end

    test "an explicit ignore_limits: false is respected when pinning", ctx do
      {:ok, task} = create(ctx)

      {:ok, pinned} =
        Ash.update(task, %{start_at: later(60), ignore_limits: false}, action: :set_schedule)

      assert pinned.ignore_limits == false
    end

    test "clearing the schedule leaves ignore_limits as sent", ctx do
      {:ok, task} = create(ctx)
      {:ok, pinned} = Ash.update(task, %{start_at: later(60)}, action: :set_schedule)

      {:ok, cleared} =
        Ash.update(pinned, %{start_at: nil, ignore_limits: false}, action: :set_schedule)

      assert cleared.start_at == nil
      assert cleared.ignore_limits == false
    end

    test "rejects a cap outside 1..100", ctx do
      {:ok, task} = create(ctx)

      assert {:error, _} = Ash.update(task, %{weekly_cap_override: 0}, action: :set_schedule)
    end

    test "rejects a deadline before the start", ctx do
      {:ok, task} = create(ctx)

      assert {:error, _} =
               Ash.update(task, %{start_at: later(7200), deadline_at: later(60)}, action: :set_schedule)
    end
  end
end
