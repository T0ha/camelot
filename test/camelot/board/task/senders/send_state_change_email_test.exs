defmodule Camelot.Board.Task.Senders.SendStateChangeEmailTest do
  use Camelot.DataCase, async: true

  import Swoosh.TestAssertions

  alias Camelot.Accounts.User
  alias Camelot.Board.Task
  alias Camelot.Board.Task.Senders.SendStateChangeEmail
  alias Camelot.Projects.Project

  setup do
    {:ok, project} =
      Ash.create(Project, %{name: "test-project", path: "/tmp/test-project"})

    creator = Ash.Seed.seed!(User, %{email: "creator@example.com"})

    {:ok, task} =
      Ash.create(Task, %{
        title: "Ship the thing",
        project_id: project.id,
        creator_id: creator.id
      })

    %{task: Ash.load!(task, :creator)}
  end

  for kind <- [:waiting_for_input, :error, :done] do
    test "delivers a branded email for kind=#{kind}", ctx do
      assert :ok = SendStateChangeEmail.send(ctx.task, unquote(kind))

      assert_email_sent(fn email ->
        assert email.to == [{"", "creator@example.com"}]
        assert email.subject =~ "Ship the thing"
        assert email.html_body =~ "/tasks/#{ctx.task.id}"
        assert email.html_body =~ "Camelot AI"
        assert email.html_body =~ "MedievalSharp"
        assert email.html_body =~ "#7c3aed"
        assert email.text_body =~ "/tasks/#{ctx.task.id}"
      end)
    end
  end
end
