defmodule Camelot.Board.Changes.DeleteAttachmentFile do
  @moduledoc """
  Ash change that deletes a `TaskAttachment`'s blob from the
  configured `Camelot.Board.AttachmentStore` before the record
  itself is destroyed, so no destroy path (container-teardown
  purge, manual delete) ever leaves an orphaned blob behind.
  """
  use Ash.Resource.Change

  alias Camelot.Board.AttachmentStore

  @impl true
  @spec change(
          Ash.Changeset.t(),
          keyword(),
          Ash.Resource.Change.context()
        ) :: Ash.Changeset.t()
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      AttachmentStore.delete(changeset.data.storage_key)
      changeset
    end)
  end
end
