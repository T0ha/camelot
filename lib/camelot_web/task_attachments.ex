defmodule CamelotWeb.TaskAttachments do
  @moduledoc """
  Shared helper wrapping `Camelot.Board.AttachmentStore.put/3` +
  `Ash.create!(Camelot.Board.TaskAttachment, ...)`, used by every
  LiveView that lets a user upload a file to a task so storing an
  attachment is one code path regardless of which view triggered it.
  """

  alias Camelot.Board.AttachmentStore
  alias Camelot.Board.TaskAttachment
  alias Phoenix.LiveView.UploadEntry

  @doc """
  Stores `tmp_path` (a `consume_uploaded_entries/3` staged file) as
  an attachment on `task_id` via the configured `AttachmentStore`
  backend, and creates the corresponding `TaskAttachment` record.
  """
  @spec store!(Ecto.UUID.t(), String.t(), UploadEntry.t()) ::
          TaskAttachment.t()
  def store!(task_id, tmp_path, %UploadEntry{} = entry) do
    {:ok, storage_key, byte_size} = AttachmentStore.put(task_id, tmp_path, entry.client_name)

    Ash.create!(TaskAttachment, %{
      filename: entry.client_name,
      content_type: entry.client_type,
      byte_size: byte_size,
      storage_key: storage_key,
      task_id: task_id
    })
  end
end
