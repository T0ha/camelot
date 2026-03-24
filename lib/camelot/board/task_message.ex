defmodule Camelot.Board.TaskMessage do
  @moduledoc """
  A conversation message on a task, enabling multi-turn
  dialogue between the AI agent and the user.
  """
  use Ash.Resource,
    domain: Camelot.Board,
    data_layer: AshPostgres.DataLayer,
    authorizers: []

  @roles [:assistant, :user]

  postgres do
    table("task_messages")
    repo(Camelot.Repo)
  end

  attributes do
    uuid_primary_key(:id)

    attribute :role, :atom do
      allow_nil?(false)
      public?(true)
      constraints(one_of: @roles)
    end

    attribute :content, :string do
      allow_nil?(false)
      public?(true)
    end

    timestamps()
  end

  relationships do
    belongs_to :task, Camelot.Board.Task do
      allow_nil?(false)
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)
      accept([:role, :content])

      argument :task_id, :uuid do
        allow_nil?(false)
      end

      change(manage_relationship(:task_id, :task, type: :append))
    end
  end
end
