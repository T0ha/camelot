defmodule Camelot.Board.Changes.DispatchTasksTest do
  use Camelot.DataCase, async: false

  alias Camelot.Accounts.Credential
  alias Camelot.Accounts.User
  alias Camelot.Agents.UsagePolicy
  alias Camelot.Agents.UsageSnapshots
  alias Camelot.Board.Changes.DispatchTasks
  alias Camelot.Board.Task
  alias Camelot.Board.TaskLink
  alias Camelot.Projects.Project
  alias Camelot.Scheduling.Windows

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

  describe "usage-limited credential gate" do
    test "a task whose credential is still usage-limited is skipped", ctx do
      {:ok, _credential} =
        Ash.create(Credential, %{
          user_id: ctx.user.id,
          kind: :claude_api_key,
          value: "secret"
        })

      task = create_task(ctx)
      credential = Credential.for_user_and_kind(ctx.user.id, :claude_api_key)

      {:ok, _} =
        Ash.update(
          credential,
          %{usage_limited_until: DateTime.add(DateTime.utc_now(), 3600, :second), usage_limit_window: "5h"},
          action: :mark_usage_limited
        )

      dispatch!()

      assert Ash.get!(Task, task.id).state == :queued
    end

    test "a task dispatches once its credential's usage limit is in the past", ctx do
      {:ok, _credential} =
        Ash.create(Credential, %{
          user_id: ctx.user.id,
          kind: :claude_api_key,
          value: "secret"
        })

      task = create_task(ctx)
      credential = Credential.for_user_and_kind(ctx.user.id, :claude_api_key)

      {:ok, _} =
        Ash.update(
          credential,
          %{usage_limited_until: DateTime.add(DateTime.utc_now(), -60, :second), usage_limit_window: "5h"},
          action: :mark_usage_limited
        )

      dispatch!()

      assert Ash.get!(Task, task.id).state == :in_progress
    end

    test "dispatch resumes due paused tasks before dispatching", ctx do
      task = create_task(ctx)

      {:ok, _} =
        Ash.update(
          task,
          %{
            paused_until: DateTime.add(DateTime.utc_now(), -60, :second),
            pause_reason: "usage limit"
          },
          action: :pause_for_usage_limit
        )

      dispatch!()

      assert Ash.get!(Task, task.id).state == :in_progress
    end
  end

  describe "usage-aware gate" do
    defp policy!(ctx, attrs) do
      UsagePolicy
      |> Ash.Changeset.for_create(
        :upsert,
        Map.merge(%{user_id: ctx.user.id, agent_id: agent!("claude_code").id}, attrs)
      )
      |> Ash.create!()
    end

    defp weekly_usage!(ctx, percent) do
      {:ok, _} =
        UsageSnapshots.record(
          ctx.user.id,
          :claude_api_key,
          [
            %{
              window: :weekly,
              used_percent: percent,
              resets_at: DateTime.add(DateTime.utc_now(), 86_400, :second)
            }
          ],
          :manual
        )
    end

    # A one-hour window starting an hour from now, so now is outside it.
    defp window_excluding_now do
      now = Windows.minute_of_week(DateTime.utc_now())
      %{start_minute: rem(now + 60, 10_080), end_minute: rem(now + 120, 10_080)}
    end

    defp gated_ids(now \\ DateTime.utc_now()) do
      Task
      |> Ash.read!(load: [:agent])
      |> DispatchTasks.apply_gate(now)
      |> Enum.map(& &1.id)
    end

    test "an over-cap card is not dispatched, and is once the cap is cleared", ctx do
      policy = policy!(ctx, %{weekly_cap_percent: 1})
      weekly_usage!(ctx, 5.0)
      task = create_task(ctx)

      dispatch!()
      assert Ash.get!(Task, task.id).state == :queued

      {:ok, _} =
        UsagePolicy
        |> Ash.Changeset.for_create(:upsert, %{
          user_id: policy.user_id,
          agent_id: policy.agent_id,
          weekly_cap_percent: nil
        })
        |> Ash.create()

      dispatch!()
      assert Ash.get!(Task, task.id).state == :in_progress
    end

    test "a window that excludes now keeps the card waiting", ctx do
      policy!(ctx, %{windows: [window_excluding_now()]})
      task = create_task(ctx)

      dispatch!()

      assert Ash.get!(Task, task.id).state == :queued
    end

    test "a pinned card is dispatched even when over the cap", ctx do
      policy!(ctx, %{weekly_cap_percent: 1})
      weekly_usage!(ctx, 5.0)
      task = create_task(ctx)

      {:ok, _} =
        Ash.update(task, %{start_at: DateTime.add(DateTime.utc_now(), -60, :second)}, action: :set_schedule)

      dispatch!()

      assert Ash.get!(Task, task.id).state == :in_progress
    end

    test "a card with a future start_at waits", ctx do
      task = create_task(ctx, %{start_at: DateTime.add(DateTime.utc_now(), 3600, :second)})

      dispatch!()

      assert Ash.get!(Task, task.id).state == :queued
    end

    test "a deadline card is dispatched ahead of a higher-priority card", ctx do
      urgent = create_task(ctx, %{priority: 10})

      deadline =
        create_task(ctx, %{
          priority: 0,
          deadline_at: DateTime.add(DateTime.utc_now(), 15 * 60, :second)
        })

      assert gated_ids() == [deadline.id, urgent.id]
    end

    test "between unpromoted cards the nearer deadline goes first, then priority", ctx do
      high = create_task(ctx, %{priority: 10})
      far = create_task(ctx, %{priority: 0, deadline_at: DateTime.add(DateTime.utc_now(), 30, :day)})

      assert gated_ids() == [far.id, high.id]
    end

    test "waiting cards expose why on the scheduled_wait calculation", ctx do
      policy!(ctx, %{weekly_cap_percent: 1})
      weekly_usage!(ctx, 5.0)
      task = create_task(ctx)

      assert %{reason: :cap, until: %DateTime{}} =
               Ash.load!(Ash.get!(Task, task.id), :scheduled_wait).scheduled_wait
    end

    test "a card with nothing gating it has no scheduled_wait", ctx do
      task = create_task(ctx)

      assert Ash.load!(task, :scheduled_wait).scheduled_wait == nil
    end
  end
end
