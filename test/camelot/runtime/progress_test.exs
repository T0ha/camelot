defmodule Camelot.Runtime.ProgressTest do
  use Camelot.DataCase, async: true

  alias Camelot.Agents.Session
  alias Camelot.Board.Task
  alias Camelot.Projects.Project
  alias Camelot.Runtime.Progress

  setup do
    user = user!()

    {:ok, project} =
      Ash.create(Project, %{name: "prog-proj", path: "/tmp/prog-proj"}, actor: user)

    {:ok, task} =
      Ash.create(Task, %{
        title: "Progress task",
        project_id: project.id,
        creator_id: user.id,
        agent_id: agent!("claude_code").id
      })

    {:ok, session} =
      Ash.create(Session, %{agent_id: task.agent_id, task_id: task.id})

    %{task: task, session: session}
  end

  describe "report/4" do
    test "broadcasts the progress line on the task topic", %{task: task, session: session} do
      Phoenix.PubSub.subscribe(Camelot.PubSub, "task:#{task.id}")

      :ok = Progress.report(task.id, session.id, :pulling_image, "Pulling the runner image…")

      assert_receive {:runner_progress, task_id, payload}
      assert task_id == task.id
      assert payload.session_id == session.id
      assert payload.phase == :pulling_image
      assert payload.message == "Pulling the runner image…"
      assert %DateTime{} = payload.at
    end

    test "persists the latest line on the session row", %{task: task, session: session} do
      :ok = Progress.report(task.id, session.id, :workspace, "Setting up the workspace…")

      reloaded = Ash.get!(Session, session.id)

      assert reloaded.progress_phase == :workspace
      assert reloaded.progress_message == "Setting up the workspace…"
      assert %DateTime{} = reloaded.progress_at
    end

    test "broadcasts without a session id", %{task: task} do
      Phoenix.PubSub.subscribe(Camelot.PubSub, "task:#{task.id}")

      :ok = Progress.report(task.id, nil, :provisioning, "Creating the runner service…")

      assert_receive {:runner_progress, _task_id, %{session_id: nil}}
    end

    test "a vanished session does not raise", %{task: task} do
      assert :ok = Progress.report(task.id, Ash.UUID.generate(), :starting, "Starting…")
    end

    test "a session without a task persists but broadcasts nowhere", %{
      task: task,
      session: session
    } do
      Phoenix.PubSub.subscribe(Camelot.PubSub, "task:#{task.id}")

      assert :ok = Progress.report(nil, session.id, :queued, "Queued for a runner slot")

      assert Ash.get!(Session, session.id).progress_message == "Queued for a runner slot"
      refute_receive {:runner_progress, _task_id, _payload}, 100
    end
  end
end
