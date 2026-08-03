defmodule Camelot.BoardTest do
  use Camelot.DataCase, async: false

  alias Camelot.Board
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
      Ash.create(Project, %{name: "purge-proj-#{System.unique_integer([:positive])}", path: "/tmp/purge"}, actor: user)

    {:ok, task} =
      Ash.create(Task, %{title: "Purge task", project_id: project.id, creator_id: user.id})

    %{task: task, base_dir: base_dir}
  end

  defp attach!(task, base_dir, filename) do
    tmp_path = Path.join(base_dir, "src-#{System.unique_integer([:positive])}.txt")
    File.mkdir_p!(base_dir)
    File.write!(tmp_path, "bytes")

    {:ok, storage_key, byte_size} = Board.AttachmentStore.put(task.id, tmp_path, filename)

    Ash.create!(TaskAttachment, %{
      filename: filename,
      byte_size: byte_size,
      storage_key: storage_key,
      task_id: task.id
    })
  end

  describe "purge_task_attachments!/1" do
    test "destroys every attachment for the task and deletes their blobs", %{task: task, base_dir: base_dir} do
      a1 = attach!(task, base_dir, "one.txt")
      a2 = attach!(task, base_dir, "two.txt")
      {:local, path1} = Board.AttachmentStore.download_url(a1.storage_key)
      {:local, path2} = Board.AttachmentStore.download_url(a2.storage_key)

      assert :ok = Board.purge_task_attachments!(task.id)

      refute File.exists?(path1)
      refute File.exists?(path2)
      assert Ash.read!(TaskAttachment) == []
    end

    test "is a no-op when the task has no attachments", %{task: task} do
      assert :ok = Board.purge_task_attachments!(task.id)
    end
  end
end
