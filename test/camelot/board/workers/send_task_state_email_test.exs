defmodule Camelot.Board.Workers.SendTaskStateEmailTest do
  use Camelot.DataCase, async: true

  import Swoosh.TestAssertions

  alias Camelot.Accounts.User
  alias Camelot.Board.Task
  alias Camelot.Board.Workers.SendTaskStateEmail
  alias Camelot.Projects.Project

  setup do
    {:ok, project} =
      Ash.create(Project, %{name: "test-project", path: "/tmp/test-project"})

    %{project: project}
  end

  defp job(task, kind) do
    %Oban.Job{args: %{"task_id" => task.id, "kind" => kind}}
  end

  describe "perform/1" do
    test "sends an email when the creator has the preference enabled", ctx do
      creator =
        Ash.Seed.seed!(User, %{
          email: "notify-on@example.com",
          notify_on_error: true
        })

      {:ok, task} =
        Ash.create(Task, %{
          title: "Needs attention",
          project_id: ctx.project.id,
          creator_id: creator.id
        })

      assert :ok = SendTaskStateEmail.perform(job(task, "error"))
      assert_email_sent(to: [{"", to_string(creator.email)}])
    end

    test "skips the email when the creator has the preference disabled", ctx do
      creator =
        Ash.Seed.seed!(User, %{
          email: "notify-off@example.com",
          notify_on_error: false
        })

      {:ok, task} =
        Ash.create(Task, %{
          title: "Needs attention",
          project_id: ctx.project.id,
          creator_id: creator.id
        })

      assert :ok = SendTaskStateEmail.perform(job(task, "error"))
      assert_no_email_sent()
    end

    test "respects the waiting_for_input preference independently", ctx do
      creator =
        Ash.Seed.seed!(User, %{
          email: "notify-mixed@example.com",
          notify_on_waiting_for_input: false,
          notify_on_done: true
        })

      {:ok, task} =
        Ash.create(Task, %{
          title: "Done task",
          project_id: ctx.project.id,
          creator_id: creator.id
        })

      assert :ok = SendTaskStateEmail.perform(job(task, "waiting_for_input"))
      assert_no_email_sent()

      assert :ok = SendTaskStateEmail.perform(job(task, "done"))
      assert_email_sent(to: [{"", to_string(creator.email)}])
    end
  end
end
