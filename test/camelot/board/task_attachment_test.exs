defmodule Camelot.Board.TaskAttachmentTest do
  use Camelot.DataCase, async: false

  alias Camelot.Board.AttachmentStore
  alias Camelot.Board.Task
  alias Camelot.Board.TaskAttachment
  alias Camelot.Projects.Project

  setup do
    base_dir = Path.join(System.tmp_dir!(), "camelot-attachments-test-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:camelot, :attachments_dir)
    Application.put_env(:camelot, :attachments_dir, base_dir)

    on_exit(fn ->
      File.rm_rf(base_dir)

      if previous do
        Application.put_env(:camelot, :attachments_dir, previous)
      else
        Application.delete_env(:camelot, :attachments_dir)
      end
    end)

    user = user!()

    {:ok, project} =
      Ash.create(Project, %{name: "attachment-proj-#{System.unique_integer([:positive])}", path: "/tmp/attach"},
        actor: user
      )

    {:ok, task} =
      Ash.create(Task, %{
        title: "Attachment task",
        project_id: project.id,
        creator_id: user.id
      })

    %{task: task, base_dir: base_dir}
  end

  defp create_attachment!(task, base_dir, attrs \\ %{}) do
    tmp_path = Path.join(base_dir, "src-#{System.unique_integer([:positive])}.txt")
    File.mkdir_p!(base_dir)
    File.write!(tmp_path, "attachment bytes")

    {:ok, storage_key, byte_size} =
      AttachmentStore.put(task.id, tmp_path, attrs[:filename] || "screenshot.png")

    Ash.create!(
      TaskAttachment,
      Map.merge(
        %{
          filename: attrs[:filename] || "screenshot.png",
          content_type: "image/png",
          byte_size: byte_size,
          storage_key: storage_key,
          task_id: task.id
        },
        Map.delete(attrs, :filename)
      )
    )
  end

  describe "create" do
    test "creates an attachment linked to its task", %{task: task, base_dir: base_dir} do
      attachment = create_attachment!(task, base_dir)

      assert attachment.filename == "screenshot.png"
      assert attachment.source == :upload
      assert attachment.task_id == task.id
    end

    test "accepts source: :github_issue", %{task: task, base_dir: base_dir} do
      attachment = create_attachment!(task, base_dir, %{source: :github_issue})
      assert attachment.source == :github_issue
    end
  end

  describe "read" do
    test "loads attachments via the task's has_many relationship", %{task: task, base_dir: base_dir} do
      create_attachment!(task, base_dir)

      loaded = Ash.load!(task, :attachments)
      assert [%TaskAttachment{}] = loaded.attachments
    end
  end

  describe "destroy" do
    test "removes the blob from the configured store", %{task: task, base_dir: base_dir} do
      attachment = create_attachment!(task, base_dir)
      {:local, path} = AttachmentStore.download_url(attachment.storage_key)

      assert File.exists?(path)
      assert :ok = Ash.destroy(attachment)
      refute File.exists?(path)
    end
  end
end
