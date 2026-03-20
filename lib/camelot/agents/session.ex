defmodule Camelot.Agents.Session do
  @moduledoc """
  A single CLI execution session tied to an agent and task.
  Tracks output, timing, and exit status.
  """
  use Ash.Resource,
    domain: Camelot.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: []

  postgres do
    table("sessions")
    repo(Camelot.Repo)
  end

  attributes do
    uuid_primary_key(:id)

    attribute :status, :atom do
      allow_nil?(false)
      public?(true)
      default(:running)

      constraints(one_of: [:running, :completed, :failed, :cancelled])
    end

    attribute :started_at, :utc_datetime do
      allow_nil?(true)
      public?(true)
    end

    attribute :finished_at, :utc_datetime do
      allow_nil?(true)
      public?(true)
    end

    attribute :output_log, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :exit_code, :integer do
      allow_nil?(true)
      public?(true)
    end

    attribute :error_message, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :retry_number, :integer do
      allow_nil?(false)
      public?(true)
      default(0)
    end

    attribute :permission_denials, {:array, :map} do
      allow_nil?(true)
      public?(true)
      default([])
      description("Tools denied by the permission system")
    end

    timestamps()
  end

  relationships do
    belongs_to :agent, Camelot.Agents.Agent do
      allow_nil?(false)
    end

    belongs_to :task, Camelot.Board.Task do
      allow_nil?(false)
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)
      accept([:started_at, :retry_number])

      argument :agent_id, :uuid do
        allow_nil?(false)
      end

      argument :task_id, :uuid do
        allow_nil?(false)
      end

      change(manage_relationship(:agent_id, :agent, type: :append))
      change(manage_relationship(:task_id, :task, type: :append))
      change(set_attribute(:started_at, &DateTime.utc_now/0))
    end

    update :complete do
      accept([
        :output_log,
        :exit_code,
        :error_message,
        :permission_denials
      ])

      change(set_attribute(:status, :completed))
      change(set_attribute(:finished_at, &DateTime.utc_now/0))
    end

    update :fail do
      accept([
        :output_log,
        :exit_code,
        :error_message,
        :permission_denials
      ])

      change(set_attribute(:status, :failed))
      change(set_attribute(:finished_at, &DateTime.utc_now/0))
    end

    update :cancel do
      change(set_attribute(:status, :cancelled))
      change(set_attribute(:finished_at, &DateTime.utc_now/0))
    end
  end
end
