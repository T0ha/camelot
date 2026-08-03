defmodule Camelot.Board.TaskAttachment do
  @moduledoc """
  A file uploaded to a task (screenshot, log, spec doc, etc.)
  so the dispatched agent can read it.

  The blob itself lives in whichever `Camelot.Board.AttachmentStore`
  backend is configured (local temp dir or S3); this resource only
  tracks the metadata and `storage_key` needed to fetch/delete it.
  Attachments are purged (blob + row) when the task's container or
  service is torn down — see `Camelot.Board.purge_task_attachments!/1`.
  """
  use Ash.Resource,
    domain: Camelot.Board,
    data_layer: AshPostgres.DataLayer,
    authorizers: []

  alias Camelot.Board.Changes.DeleteAttachmentFile

  @sources [:upload, :github_issue]

  postgres do
    table("task_attachments")
    repo(Camelot.Repo)
  end

  attributes do
    uuid_primary_key(:id)

    attribute :filename, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :content_type, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :byte_size, :integer do
      allow_nil?(true)
      public?(true)
    end

    attribute :storage_key, :string do
      allow_nil?(false)
      public?(false)
    end

    attribute :source, :atom do
      allow_nil?(false)
      public?(true)
      default(:upload)
      constraints(one_of: @sources)
    end

    timestamps()
  end

  relationships do
    belongs_to :task, Camelot.Board.Task do
      allow_nil?(false)
    end
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)
      accept([:filename, :content_type, :byte_size, :storage_key, :source])

      argument :task_id, :uuid do
        allow_nil?(false)
      end

      change(manage_relationship(:task_id, :task, type: :append))
    end

    destroy :destroy do
      primary?(true)
      require_atomic?(false)
      change(DeleteAttachmentFile)
    end
  end

  @doc """
  Returns all valid attachment sources.
  """
  @spec sources() :: [atom()]
  def sources, do: @sources
end
