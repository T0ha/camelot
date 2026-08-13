defmodule Camelot.Github.IssueAttachmentsImportTest do
  use Camelot.DataCase, async: false

  alias Camelot.Board.Task
  alias Camelot.Board.TaskAttachment
  alias Camelot.Github.IssueAttachments
  alias Camelot.Projects.Project

  setup do
    user = user!()

    {:ok, project} =
      Ash.create(Project, %{name: "issue-attach-#{System.unique_integer([:positive])}", path: "/tmp/ia"}, actor: user)

    {:ok, task} =
      Ash.create(Task, %{title: "From issue", project_id: project.id, creator_id: user.id})

    %{task: task}
  end

  describe "import_from_issue!/2" do
    test "is a no-op for a body with no attachment urls", %{task: task} do
      assert :ok = IssueAttachments.import_from_issue!(task, "just plain text, nothing to import")
      assert Ash.load!(task, :attachments).attachments == []
    end

    test "is a no-op for a nil body", %{task: task} do
      assert :ok = IssueAttachments.import_from_issue!(task, nil)
      assert Ash.load!(task, :attachments).attachments == []
    end

    test "skips (without crashing) a url that fails to fetch", %{task: task} do
      # Nothing listens on 127.0.0.1:1 — a fast, network-independent
      # connection refusal, exercising the per-URL failure path
      # without depending on outbound internet access in CI.
      body = "![broken](http://127.0.0.1:1/missing.png)"

      assert :ok = IssueAttachments.import_from_issue!(task, body)
      assert Ash.read!(TaskAttachment) == []
    end
  end
end
