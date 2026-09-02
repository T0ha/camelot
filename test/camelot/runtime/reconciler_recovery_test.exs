defmodule Camelot.Runtime.ReconcilerRecoveryTest do
  # Touches the DB (tasks + sessions) and the interruption re-queue cap
  # in the app env, so it can't run async.
  use Camelot.DataCase, async: false

  alias Camelot.Agents.Session
  alias Camelot.Board.Task
  alias Camelot.Projects.Project
  alias Camelot.Runtime.Reconciler
  alias Camelot.Runtime.RunnerPool

  setup do
    {:ok, project} =
      Ash.create(Project, %{name: "recovery-project", path: "/tmp/recovery"})

    %{project: project, user: user!(), agent: agent!("claude_code")}
  end

  defp task!(ctx, attrs \\ %{}) do
    {:ok, task} =
      Ash.create(
        Task,
        Map.merge(
          %{
            title: "Recovered task",
            project_id: ctx.project.id,
            creator_id: ctx.user.id,
            agent_id: ctx.agent.id
          },
          attrs
        )
      )

    task
  end

  defp session!(ctx, task, status) do
    {:ok, session} =
      Ash.create(Session, %{
        agent_id: ctx.agent.id,
        task_id: task.id,
        user_id: ctx.user.id,
        kind: :task
      })

    mark(session, status)
  end

  defp mark(session, :queued), do: session

  defp mark(session, :running) do
    {:ok, running} = Ash.update(session, %{service_id: "svc-1"}, action: :mark_running)
    running
  end

  defp reload(%Task{id: id}), do: Ash.get!(Task, id)
  defp reload(%Session{id: id}), do: Ash.get!(Session, id)

  describe "recover_interrupted_task/3" do
    test "fails the in-flight sessions and re-queues the task", ctx do
      task = task!(ctx)
      {:ok, task} = Ash.update(task, %{}, action: :begin_work)
      {:ok, task} = Ash.update(task, %{runner_handle: "svc-1"}, action: :set_runner_handle)

      running = session!(ctx, task, :running)
      queued = session!(ctx, task, :queued)

      assert :ok = Reconciler.recover_interrupted_task(task.id, "container replaced")

      assert reload(running).status == :failed
      assert reload(running).error_message =~ "container replaced"
      assert reload(queued).status == :failed

      task = reload(task)
      assert task.state == :queued
      assert task.stage == :planning
      assert task.interrupt_requeues == 1
    end

    test "clears the runner handle by default", ctx do
      task = task!(ctx)
      {:ok, task} = Ash.update(task, %{runner_handle: "svc-1"}, action: :set_runner_handle)

      assert :ok = Reconciler.recover_interrupted_task(task.id, "runner lost")

      assert reload(task).runner_handle == nil
    end

    test "keeps the runner handle when asked", ctx do
      task = task!(ctx)
      {:ok, task} = Ash.update(task, %{runner_handle: "svc-1"}, action: :set_runner_handle)

      assert :ok =
               Reconciler.recover_interrupted_task(
                 task.id,
                 "image rolled",
                 keep_runner_handle: true
               )

      assert reload(task).runner_handle == "svc-1"
    end

    test "leaves finished sessions alone", ctx do
      task = task!(ctx)
      running = session!(ctx, task, :running)
      {:ok, done} = Ash.update(running, %{exit_code: 0}, action: :complete)

      assert :ok = Reconciler.recover_interrupted_task(task.id, "image rolled")

      assert reload(done).status == :completed
    end

    test "never raises for an unknown task" do
      assert :ok = Reconciler.recover_interrupted_task(Ash.UUID.generate(), "image rolled")
    end

    test "leaves a cancelled task alone", ctx do
      task = task!(ctx)
      {:ok, task} = Ash.update(task, %{}, action: :cancel)

      assert :ok = Reconciler.recover_interrupted_task(task.id, "image rolled")

      assert reload(task).stage == :cancelled
    end
  end

  describe "recover_stale_queued_sessions/0" do
    # `queued_at` is stamped by the create action, and the sweep gives a
    # 60s grace, so an orphan has to be aged past it to be visible.
    defp age_queued(session, ms) do
      Ash.Seed.update!(session, %{
        queued_at: DateTime.add(DateTime.utc_now(), -ms, :millisecond)
      })
    end

    test "recovers a session the restart left queued with no owner", ctx do
      task = task!(ctx)
      {:ok, task} = Ash.update(task, %{}, action: :begin_work)
      queued = ctx |> session!(task, :queued) |> age_queued(120_000)

      assert :ok = Reconciler.recover_stale_queued_sessions()

      assert reload(queued).status == :failed
      assert reload(queued).error_message =~ "restarted"

      task = reload(task)
      assert task.state == :queued
      assert task.interrupt_requeues == 1
    end

    test "leaves a session that is legitimately waiting for a pool slot", ctx do
      task = task!(ctx)
      {:ok, task} = Ash.update(task, %{}, action: :begin_work)
      queued = ctx |> session!(task, :queued) |> age_queued(120_000)

      # Exactly what a session waiting behind the per-user cap looks
      # like: old, :queued, no SessionRegistry entry — but a live waiter
      # in the pool. Recovering it would kill a perfectly good dispatch.
      {:ok, _} = RunnerPool.enqueue(ctx.user.id, queued.id, self())
      on_exit(fn -> RunnerPool.cancel(ctx.user.id, queued.id) end)

      assert RunnerPool.tracking?(queued.id)
      assert :ok = Reconciler.recover_stale_queued_sessions()

      assert reload(queued).status == :queued
      assert reload(task).state == :in_progress
      assert reload(task).interrupt_requeues == 0
    end

    test "leaves a freshly queued session inside the grace window", ctx do
      task = task!(ctx)
      {:ok, task} = Ash.update(task, %{}, action: :begin_work)
      queued = session!(ctx, task, :queued)

      assert :ok = Reconciler.recover_stale_queued_sessions()

      assert reload(queued).status == :queued
      assert reload(task).state == :in_progress
    end

    test "ignores bootstrap sessions with no task", ctx do
      {:ok, bootstrap} =
        Ash.create(Session, %{
          agent_id: ctx.agent.id,
          user_id: ctx.user.id,
          kind: :bootstrap,
          bootstrap_kind: :prewarm
        })

      age_queued(bootstrap, 120_000)

      assert :ok = Reconciler.recover_stale_queued_sessions()

      assert reload(bootstrap).status == :queued
    end
  end
end
