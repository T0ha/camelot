defmodule CamelotWeb.TaskLiveTest do
  use CamelotWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Camelot.Agents.Session
  alias Camelot.Board.Task
  alias Camelot.Board.TaskMessage
  alias Camelot.Projects.Project

  setup :register_and_log_in_user

  setup %{user: user} do
    {:ok, project} =
      Ash.create(
        Project,
        %{name: "task-live-proj", path: "/tmp/task-live-proj"},
        actor: user
      )

    {:ok, task} =
      Ash.create(Task, %{
        title: "Live task",
        description: "A task for live testing",
        project_id: project.id,
        creator_id: user.id,
        agent_id: agent!("claude_code").id
      })

    %{task: task, project: project}
  end

  describe "mount" do
    test "renders task detail", %{conn: conn, task: task} do
      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")
      assert html =~ "Live task"
      assert html =~ "todo"
    end

    test "plan section without a distinct full plan only links to download", %{
      conn: conn,
      project: project,
      user: user
    } do
      task =
        Ash.Seed.seed!(Task, %{
          title: "Planned task",
          project_id: project.id,
          creator_id: user.id,
          plan: "See ~/.claude/plans/x.md — summary."
        })

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      refute html =~ "Full plan"
      refute html =~ ~s(href="#{~p"/tasks/#{task.id}/plan"}")
      assert html =~ ~s(href="#{~p"/tasks/#{task.id}/plan/download"}")
    end

    test "plan section with a distinct full plan links to both full plan and download", %{
      conn: conn,
      project: project,
      user: user
    } do
      task =
        Ash.Seed.seed!(Task, %{
          title: "Planned task",
          project_id: project.id,
          creator_id: user.id,
          plan: "See ~/.claude/plans/x.md — summary.",
          full_plan: "# Full plan\n\nThe complete plan document."
        })

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert html =~ ~s(href="#{~p"/tasks/#{task.id}/plan"}")
      assert html =~ ~s(href="#{~p"/tasks/#{task.id}/plan/download"}")
    end

    test "renders GFM markdown tables in the description", %{conn: conn, project: project, user: user} do
      {:ok, task} =
        Ash.create(Task, %{
          title: "Tabular task",
          description: "| A | B |\n|---|---|\n| 1 | 2 |",
          project_id: project.id,
          creator_id: user.id,
          agent_id: agent!("claude_code").id
        })

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert html =~ "<table>"
      assert html =~ "<th>A</th>"
      refute html =~ "| A | B |"
    end
  end

  describe "error reason" do
    test "shows last_error when the task is in error", %{conn: conn, task: task} do
      {:ok, task} = Ash.update(task, %{}, action: :begin_work)

      {:ok, task} =
        Ash.update(
          task,
          %{last_error: "runner lost: service returned 404"},
          action: :mark_error
        )

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert html =~ "This task stopped with an error"
      assert html =~ "runner lost: service returned 404"
    end

    test "shows nothing for a healthy task", %{conn: conn, task: task} do
      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      refute html =~ "This task stopped with an error"
    end
  end

  describe "cancel" do
    test "cancels a task", %{conn: conn, task: task} do
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert view
             |> element("button", "Cancel")
             |> render_click() =~ "cancelled"
    end
  end

  describe "reset_task" do
    test "re-queues a stuck task", %{conn: conn, task: task} do
      {:ok, task} = Ash.update(task, %{}, action: :begin_work)

      assert task.stage == :planning
      assert task.state == :in_progress

      {:ok, view, html} = live(conn, ~p"/tasks/#{task.id}")
      assert html =~ "Reset Task"

      html =
        view
        |> element("button", "Reset Task")
        |> render_click()

      assert html =~ "work will resume"

      reloaded = Ash.get!(Task, task.id)
      assert reloaded.state == :queued
      assert reloaded.stage == :planning
    end

    test "button is hidden when the task isn't stuck", %{conn: conn, task: task} do
      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")
      refute html =~ "Reset Task"
    end
  end

  describe "live output" do
    setup %{task: task} do
      {:ok, task} = Ash.update(task, %{}, action: :begin_work)

      {:ok, session} =
        Ash.create(Session, %{agent_id: task.agent_id, task_id: task.id})

      {:ok, session} = Ash.update(session, %{}, action: :mark_running)

      %{task: task, session: session}
    end

    test "streamed output renders inside the running session card", %{conn: conn, task: task} do
      {:ok, view, html} = live(conn, ~p"/tasks/#{task.id}")

      refute html =~ "Live output"

      send(view.pid, {:agent_output, task.id, ~s({"type":"result","result":"hello"}\n)})

      html = render(view)

      assert html =~ "Sessions"
      assert html =~ "running"
      assert html =~ "Live output"
      assert html =~ "hello"
    end

    test "no Live output heading when buffer is empty", %{conn: conn, task: task} do
      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      refute html =~ "Live output"
    end
  end

  describe "session output log" do
    setup %{task: task} do
      {:ok, task} = Ash.update(task, %{}, action: :begin_work)
      {:ok, session} = Ash.create(Session, %{agent_id: task.agent_id, task_id: task.id})

      %{task: task, session: session}
    end

    test "a failed session's large output log is truncated to its tail in the render",
         %{conn: conn, task: task, session: session} do
      log = "HEAD_MARKER" <> String.duplicate("x", 30_000) <> "TAIL_MARKER"

      {:ok, _session} =
        Ash.update(session, %{output_log: log, exit_code: 1}, action: :fail)

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert html =~ "TAIL_MARKER"
      refute html =~ "HEAD_MARKER"
      assert html =~ "truncated"
    end

    test "a failed session's small output log renders in full without truncation",
         %{conn: conn, task: task, session: session} do
      {:ok, _session} =
        Ash.update(session, %{output_log: "SHORT_OUTPUT", exit_code: 1}, action: :fail)

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert html =~ "SHORT_OUTPUT"
      refute html =~ "truncated"
    end

    test "a completed session shows a download link instead of the inline log",
         %{conn: conn, task: task, session: session} do
      log = "HEAD_MARKER" <> String.duplicate("x", 30_000) <> "TAIL_MARKER"

      {:ok, session} =
        Ash.update(session, %{output_log: log, exit_code: 0}, action: :complete)

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      refute html =~ "HEAD_MARKER"
      refute html =~ "TAIL_MARKER"
      refute html =~ "truncated"
      assert html =~ "Download logs"
      assert html =~ ~p"/sessions/#{session.id}/download"
    end
  end

  describe "run stats" do
    test "renders message timestamps and session cost/duration/tokens", %{
      conn: conn,
      task: task
    } do
      inserted_at = ~U[2026-08-25 10:05:00Z]

      Ash.Seed.seed!(TaskMessage, %{
        role: :assistant,
        content: "Working on it.",
        task_id: task.id,
        inserted_at: inserted_at
      })

      Ash.Seed.seed!(Session, %{
        agent_id: task.agent_id,
        task_id: task.id,
        status: :completed,
        queued_at: ~U[2026-08-25 10:00:00Z],
        started_at: ~U[2026-08-25 10:03:00Z],
        finished_at: ~U[2026-08-25 10:07:00Z],
        cost_usd: 0.1234,
        duration_ms: 65_000,
        num_turns: 5,
        usage: %{
          "input_tokens" => 100,
          "output_tokens" => 50,
          "cache_read_input_tokens" => 30,
          "cache_creation_input_tokens" => 10
        }
      })

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert html =~ "2026-08-25 10:05"
      assert html =~ "Started 2026-08-25 10:03"
      assert html =~ "Finished 2026-08-25 10:07"
      assert html =~ "1m 5s"
      assert html =~ "$0.1234"
      assert html =~ "Turns"
      assert html =~ "5"
      assert html =~ "in 100"
      assert html =~ "out 50"
      assert html =~ "cache read 30"
      assert html =~ "cache write 10"
    end
  end

  describe "pubsub" do
    test "ignores unrelated PubSub messages without crashing", %{conn: conn, task: task} do
      {:ok, _task} = Ash.update(task, %{}, action: :begin_work)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      send(view.pid, {:some_unexpected_message, :payload})

      assert render(view) =~ "Live task"
    end
  end

  describe "column focus" do
    test "toggling a column expands it to full width", %{conn: conn, task: task} do
      {:ok, view, html} = live(conn, ~p"/tasks/#{task.id}")
      refute html =~ "Restore split view"

      html =
        view
        |> element(~s(button[phx-value-col="left"]))
        |> render_click()

      assert html =~ "Restore split view"
      assert html =~ "hero-arrows-pointing-in"
    end

    test "toggling the same column again restores the split view", %{conn: conn, task: task} do
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      button = fn -> element(view, ~s(button[phx-value-col="left"])) end

      render_click(button.())
      html = render_click(button.())

      refute html =~ "Restore split view"
    end
  end

  describe "attachments" do
    setup %{task: task} do
      on_exit(fn ->
        System.tmp_dir!()
        |> Path.join("camelot-attachments/#{task.id}")
        |> File.rm_rf()
      end)

      :ok
    end

    test "uploading a file lists it with a download link", %{conn: conn, task: task} do
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      file =
        file_input(view, "#attachment-upload-form", :attachment, [
          %{
            name: "screenshot.png",
            content: "fake png bytes",
            type: "image/png"
          }
        ])

      html =
        file
        |> render_upload("screenshot.png")
        |> then(fn _ -> view |> element("#attachment-upload-form") |> render_submit() end)

      assert html =~ "screenshot.png"
      assert html =~ ~s(/attachments/)

      {:ok, reloaded} = Ash.load(task, :attachments)
      assert [%{filename: "screenshot.png"}] = reloaded.attachments
    end

    test "deleting an attachment removes it from the list", %{conn: conn, task: task} do
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      file =
        file_input(view, "#attachment-upload-form", :attachment, [
          %{name: "log.txt", content: "boom", type: "text/plain"}
        ])

      render_upload(file, "log.txt")
      view |> element("#attachment-upload-form") |> render_submit()

      {:ok, reloaded} = Ash.load(task, :attachments)
      [attachment] = reloaded.attachments

      html =
        view
        |> element(~s(button[phx-value-id="#{attachment.id}"]))
        |> render_click()

      refute html =~ "log.txt"
    end
  end

  describe "scoping" do
    test "redirects non-member from another user's task", %{conn: conn} do
      other = Ash.Seed.seed!(Camelot.Accounts.User, %{email: "to-#{System.unique_integer()}@x.com"})

      {:ok, project} =
        Ash.create(
          Project,
          %{name: "scope-task-#{System.unique_integer()}", path: "/tmp/st"},
          actor: other
        )

      {:ok, other_task} =
        Ash.create(Task, %{
          title: "Other's task",
          project_id: project.id,
          creator_id: other.id,
          agent_id: agent!("claude_code").id
        })

      assert {:error, {kind, %{to: "/"}}} =
               live(conn, ~p"/tasks/#{other_task.id}")

      assert kind in [:redirect, :live_redirect]
    end
  end

  describe "provisioning progress" do
    setup %{task: task} do
      {:ok, task} = Ash.update(task, %{}, action: :begin_work)

      {:ok, session} =
        Ash.create(Session, %{agent_id: task.agent_id, task_id: task.id})

      {:ok, session} = Ash.update(session, %{}, action: :mark_running)

      %{task: task, session: session}
    end

    # The "frozen page" report: a session sits `running` for minutes
    # while Swarm pulls the image and the entrypoint clones + installs,
    # and the card said nothing at all.
    test "a running session with no output yet shows a runner status line",
         %{conn: conn, task: task} do
      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert html =~ "Runner status"
      assert html =~ "Preparing the runner"
      refute html =~ "Live output"
    end

    test "a broadcast progress line replaces the generic placeholder",
         %{conn: conn, task: task, session: session} do
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      send(
        view.pid,
        {:runner_progress, task.id,
         %{
           session_id: session.id,
           phase: :pulling_image,
           message: "Pulling the runner image…",
           at: DateTime.utc_now()
         }}
      )

      html = render(view)

      assert html =~ "Pulling the runner image"
      refute html =~ "Preparing the runner"
    end

    test "progress for another session is ignored", %{conn: conn, task: task} do
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      send(
        view.pid,
        {:runner_progress, task.id,
         %{
           session_id: Ash.UUID.generate(),
           phase: :pulling_image,
           message: "Pulling the runner image…",
           at: DateTime.utc_now()
         }}
      )

      html = render(view)

      refute html =~ "Pulling the runner image"
      assert html =~ "Preparing the runner"
    end

    # A viewer opening the page mid-provisioning gets the last line
    # from the session row rather than a bare placeholder.
    test "the persisted progress line renders on mount",
         %{conn: conn, task: task, session: session} do
      {:ok, _session} =
        Ash.update(
          session,
          %{progress_phase: :workspace, progress_message: "Setting up the workspace…"},
          action: :report_progress
        )

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert html =~ "Setting up the workspace"
    end

    test "the status line gives way to live output once the agent speaks",
         %{conn: conn, task: task} do
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      send(view.pid, {:agent_output, task.id, ~s({"type":"result","result":"hello"}\n)})

      html = render(view)

      assert html =~ "Live output"
      assert html =~ "hello"
      refute html =~ "Runner status"
    end
  end
end
