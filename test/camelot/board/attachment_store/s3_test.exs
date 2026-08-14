defmodule Camelot.Board.AttachmentStore.S3Test do
  use ExUnit.Case, async: false

  alias Camelot.Board.AttachmentStore.S3

  setup do
    previous = Application.get_env(:camelot, :attachment_store_s3)

    Application.put_env(:camelot, :attachment_store_s3,
      endpoint: "https://compat.objectstorage.example.com",
      bucket: "camelot-attachments",
      access_key_id: "test-key",
      secret_access_key: "test-secret",
      region: "us-ashburn-1"
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:camelot, :attachment_store_s3, previous)
      else
        Application.delete_env(:camelot, :attachment_store_s3)
      end
    end)

    :ok
  end

  describe "download_url/1" do
    test "returns a presigned GET URL for the configured bucket/endpoint" do
      {:ok, url} = S3.download_url("tasks/task-1/abc-notes.txt")

      assert url =~ "https://compat.objectstorage.example.com/camelot-attachments/tasks/task-1/abc-notes.txt"
      assert url =~ "X-Amz-Algorithm=AWS4-HMAC-SHA256"
      assert url =~ "X-Amz-Credential=test-key"
    end

    test "presigned URLs for different keys differ" do
      {:ok, url_a} = S3.download_url("tasks/task-1/a.txt")
      {:ok, url_b} = S3.download_url("tasks/task-1/b.txt")

      refute url_a == url_b
    end
  end
end
