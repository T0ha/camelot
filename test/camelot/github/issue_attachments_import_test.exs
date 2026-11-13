defmodule Camelot.Github.IssueAttachmentsImportTest do
  use Camelot.DataCase, async: true

  alias Camelot.Board.Task
  alias Camelot.Board.TaskAttachment
  alias Camelot.Board.TaskMessage
  alias Camelot.Github.IssueAttachments
  alias Camelot.Projects.Project

  require Ash.Query

  @file_url "https://github.com/user-attachments/files/34787789/report.xlsx"

  setup do
    user = user!()

    {:ok, project} =
      Ash.create(Project, %{name: "issue-attach-#{System.unique_integer([:positive])}", path: "/tmp/ia"}, actor: user)

    {:ok, task} =
      Ash.create(Task, %{
        title: "From issue",
        project_id: project.id,
        creator_id: user.id,
        agent_id: agent!("claude_code").id
      })

    %{task: task}
  end

  defp stub(handler), do: Req.Test.stub(IssueAttachments, handler)

  defp stub_file(content \\ "xlsx-bytes") do
    stub(fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/octet-stream")
      |> Plug.Conn.send_resp(200, content)
    end)
  end

  defp attachments(task) do
    TaskAttachment
    |> Ash.Query.filter(task_id == ^task.id)
    |> Ash.read!()
  end

  defp messages(task) do
    TaskMessage
    |> Ash.Query.filter(task_id == ^task.id)
    |> Ash.read!()
  end

  describe "import_from_issue!/2" do
    test "is a no-op for a body with no attachment urls", %{task: task} do
      assert :ok = IssueAttachments.import_from_issue!(task, "just plain text, nothing to import")
      assert attachments(task) == []
    end

    test "is a no-op for a nil body", %{task: task} do
      assert :ok = IssueAttachments.import_from_issue!(task, nil)
      assert attachments(task) == []
    end

    test "imports a `files/` link as a :github_issue attachment", %{task: task} do
      stub_file()

      assert :ok = IssueAttachments.import_from_issue!(task, "[report.xlsx](#{@file_url})")

      assert [attachment] = attachments(task)
      assert attachment.filename == "report.xlsx"
      assert attachment.source == :github_issue
      assert attachment.source_url == @file_url
      assert attachment.byte_size == byte_size("xlsx-bytes")
    end
  end

  describe "import_from_body/3" do
    test "tags comment imports :github_comment", %{task: task} do
      stub_file()

      assert [{:imported, @file_url, attachment}] =
               IssueAttachments.import_from_body(task, @file_url, source: :github_comment)

      assert attachment.source == :github_comment
    end

    test "does not import the same url twice for a task", %{task: task} do
      stub_file()

      IssueAttachments.import_from_body(task, @file_url, source: :github_comment)

      assert [{:existing, @file_url, %TaskAttachment{filename: "report.xlsx"}}] =
               IssueAttachments.import_from_body(task, @file_url, source: :github_comment)

      assert length(attachments(task)) == 1
    end

    test "suffixes a filename already used on the task", %{task: task} do
      stub_file()
      other = "https://github.com/user-attachments/files/2/report.xlsx"

      IssueAttachments.import_from_body(task, "#{@file_url} #{other}", source: :github_comment)

      assert task |> attachments() |> Enum.map(& &1.filename) |> Enum.sort() ==
               ["report-2.xlsx", "report.xlsx"]
    end

    test "names an extensionless asset from its content type", %{task: task} do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("image/png")
        |> Plug.Conn.send_resp(200, "png")
      end)

      url = "https://github.com/user-attachments/assets/aaaa-bbbb"

      assert [{:imported, ^url, attachment}] =
               IssueAttachments.import_from_body(task, "![x](#{url})", source: :github_comment)

      assert attachment.filename == "aaaa-bbbb.png"
      assert attachment.content_type == "image/png"
    end

    test "keeps the raw bytes of a JSON attachment", %{task: task} do
      stub(&Req.Test.json(&1, %{"a" => 1}))
      url = "https://github.com/user-attachments/files/3/data.json"

      assert [{:imported, ^url, attachment}] =
               IssueAttachments.import_from_body(task, url, source: :github_comment)

      assert attachment.byte_size == byte_size(~s({"a":1}))
    end

    test "records a visible message for a url that fails", %{task: task} do
      stub(&Plug.Conn.send_resp(&1, 404, "Not Found"))

      assert [{:failed, @file_url, "HTTP 404"}] =
               IssueAttachments.import_from_body(task, @file_url, source: :github_comment)

      assert attachments(task) == []
      assert [%{role: :user, content: content}] = messages(task)
      assert content =~ "Couldn't import attachment report.xlsx"
      assert content =~ "HTTP 404"
    end

    test "rejects a file over the size cap", %{task: task} do
      stub_file(String.duplicate("x", 11))

      assert [{:failed, @file_url, "file is larger than 10 bytes"}] =
               IssueAttachments.import_from_body(task, @file_url, source: :github_comment, max_bytes: 10)

      assert attachments(task) == []
    end
  end
end
