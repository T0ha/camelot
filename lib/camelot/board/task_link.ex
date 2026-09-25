defmodule Camelot.Board.TaskLink do
  @moduledoc """
  A directed edge between two `Camelot.Board.Task` rows.

  Three link types, all creatable from either task's page regardless
  of which project owns them:

    * `:blocks` — the source task must open a PR (reach stage `:pr`,
      or terminate at `:done`/`:cancelled`) before the target task may
      dispatch. Same-repo blockers additionally drive stacked branches
      (see `Camelot.Board.PromptBuilder`) and rebase notices (see
      `Camelot.Board.Changes.CheckPrStatus`).
    * `:parent_of` — the source task is the umbrella task, the target
      is one of its subtasks. A task can have at most one parent
      (`unique_parent`); it gates the same way `:blocks` does, just in
      the other direction — the parent waits on every subtask.
    * `:relates_to` — informational cross-reference. Symmetric, and
      never gates dispatch. Stored with the smaller task id as
      `source_task_id` (see `Changes.CanonicalizeRelatesTo`) so the two
      directions of the same fact can't both be inserted.

  A surrogate `uuid_primary_key` is used instead of the composite
  `(source_task_id, target_task_id, link_type)` key that
  `lib/camelot/projects/membership.ex` uses for its join resource,
  because a link needs a single id for its `phx-value-id` delete
  button in the UI. The field is `link_type` rather than `type`
  because `type/2` is an Ash expression function and an attribute
  named `type` shadows it badly inside `expr()`.
  """
  use Ash.Resource,
    domain: Camelot.Board,
    data_layer: AshPostgres.DataLayer,
    authorizers: []

  alias Camelot.Board.TaskLink.Changes.CanonicalizeRelatesTo
  alias Camelot.Board.TaskLink.Changes.RejectCycle
  alias Camelot.Board.TaskLink.Validations.NoSelfLink

  @link_types [:blocks, :parent_of, :relates_to]

  postgres do
    table("task_links")
    repo(Camelot.Repo)

    # Required escape hatch for the partial `:unique_parent` index
    # below — the repo already does this in
    # `lib/camelot/projects/env_var.ex`.
    identity_wheres_to_sql(unique_parent: "link_type = 'parent_of'")

    references do
      reference(:source_task, on_delete: :delete, index?: true)
      reference(:target_task, on_delete: :delete, index?: true)
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :link_type, :atom do
      allow_nil?(false)
      public?(true)
      constraints(one_of: @link_types)
    end

    attribute :base_synced_sha, :string do
      allow_nil?(true)
      public?(true)

      description(
        "Head sha of the blocker's PR branch that the dependent has " <>
          "already been told to rebase onto. Only meaningful for " <>
          "`:blocks` links — see `Camelot.Board.Changes.CheckPrStatus`. " <>
          "It lives here because the sync is a property of the edge " <>
          "and is a single value per edge; a dedicated sync resource " <>
          "is the move once a link needs more than one (say, rebased " <>
          "but not yet pushed)."
      )
    end

    attribute :base_synced_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    timestamps()
  end

  relationships do
    belongs_to :source_task, Camelot.Board.Task do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end

    belongs_to :target_task, Camelot.Board.Task do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end
  end

  identities do
    identity(:unique_link, [:source_task_id, :target_task_id, :link_type])

    identity :unique_parent, [:target_task_id] do
      where(expr(link_type == :parent_of))
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)
      accept([:source_task_id, :target_task_id, :link_type])

      change(CanonicalizeRelatesTo)
      validate(NoSelfLink)
      change(RejectCycle)
    end

    update :sync_base do
      accept([:base_synced_sha, :base_synced_at])
    end
  end

  @doc """
  Returns all valid task link types.
  """
  @spec link_types() :: [atom()]
  def link_types, do: @link_types
end
