defmodule Camelot.Board.AttachmentStore.LocalTest do
  use ExUnit.Case, async: false

  alias Camelot.Board.AttachmentStore.Local

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

    tmp_path = Path.join(System.tmp_dir!(), "upload-#{System.unique_integer([:positive])}.txt")
    File.write!(tmp_path, "hello world")
    on_exit(fn -> File.rm(tmp_path) end)

    %{base_dir: base_dir, tmp_path: tmp_path}
  end

  describe "put/3" do
    test "copies the file under <base>/<task_id>/ and returns a storage key + size", %{tmp_path: tmp_path} do
      task_id = Ecto.UUID.generate()

      assert {:ok, storage_key, 11} = Local.put(task_id, tmp_path, "notes.txt")
      assert storage_key =~ ~r{^#{task_id}/[0-9a-f-]+-notes\.txt$}

      {:local, path} = Local.download_url(storage_key)
      assert File.read!(path) == "hello world"
    end

    test "sanitizes an unsafe filename", %{tmp_path: tmp_path} do
      task_id = Ecto.UUID.generate()

      assert {:ok, storage_key, _size} = Local.put(task_id, tmp_path, "../../etc/passwd")

      {:local, path} = Local.download_url(storage_key)
      refute String.contains?(path, "..")
      assert File.read!(path) == "hello world"
    end
  end

  describe "delete/1" do
    test "removes the blob from disk", %{tmp_path: tmp_path} do
      task_id = Ecto.UUID.generate()
      {:ok, storage_key, _size} = Local.put(task_id, tmp_path, "gone.txt")
      {:local, path} = Local.download_url(storage_key)

      assert File.exists?(path)
      assert Local.delete(storage_key) == :ok
      refute File.exists?(path)
    end

    test "is a no-op when the blob is already gone" do
      assert Local.delete(Path.join(Ecto.UUID.generate(), "missing.txt")) == :ok
    end
  end
end
