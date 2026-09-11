defmodule Camelot.Agents.Session do
  @moduledoc """
  A single CLI execution session tied to an agent CLI and task.
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

  @kinds [:task, :bootstrap]
  @bootstrap_kinds [
    :asdf_install,
    :mcp_install,
    :claude_login,
    :gh_login,
    :prewarm,
    :custom
  ]
  @statuses [:queued, :running, :completed, :failed, :cancelled, :empty]

  # Coarse provisioning phases a session passes through *before* the
  # agent CLI produces its first byte. Reported by
  # `Camelot.Runtime.Progress`; purely informational.
  @progress_phases [
    :queued,
    :provisioning,
    :pulling_image,
    :starting,
    :workspace,
    :running
  ]

  attributes do
    uuid_primary_key(:id)

    attribute :status, :atom do
      allow_nil?(false)
      public?(true)
      default(:queued)

      constraints(one_of: @statuses)
    end

    attribute :kind, :atom do
      allow_nil?(false)
      public?(true)
      default(:task)
      constraints(one_of: @kinds)
      description("Whether this session is a task or a bootstrap (cache mutation)")
    end

    attribute :bootstrap_kind, :atom do
      allow_nil?(true)
      public?(true)
      constraints(one_of: @bootstrap_kinds)
      description("Descriptive sub-type for :bootstrap kind sessions")
    end

    attribute :queued_at, :utc_datetime do
      allow_nil?(true)
      public?(true)
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

    attribute :cost_usd, :float do
      allow_nil?(true)
      public?(true)
      description("Session cost in USD, as reported by the CLI's result event")
    end

    attribute :duration_ms, :integer do
      allow_nil?(true)
      public?(true)
      description("Total wall-clock duration of the CLI run, in milliseconds")
    end

    attribute :duration_api_ms, :integer do
      allow_nil?(true)
      public?(true)
      description("Time spent waiting on API responses, in milliseconds")
    end

    attribute :num_turns, :integer do
      allow_nil?(true)
      public?(true)
      description("Number of conversational turns in the CLI run")
    end

    attribute :usage, :map do
      allow_nil?(true)
      public?(true)
      description("Raw token-usage object reported by the CLI's result event")
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

    attribute :clarified, :boolean do
      allow_nil?(false)
      public?(true)
      default(false)
      description("Whether denials have been addressed by the user")
    end

    attribute :service_id, :string do
      allow_nil?(true)
      public?(true)

      description(
        "Swarm/Docker service or container ID. Fast-lookup " <>
          "index only; authoritative naming is " <>
          "`camelot-runner-<session_id>`."
      )
    end

    attribute :progress_phase, :atom do
      allow_nil?(true)
      public?(true)
      constraints(one_of: @progress_phases)

      description(
        "Coarse phase of the runner hand-off (queueing, image " <>
          "pull, container start, workspace setup) while the " <>
          "session has produced no agent output yet."
      )
    end

    attribute :progress_message, :string do
      allow_nil?(true)
      public?(true)

      description(
        "Human-readable line for `progress_phase`, shown on the " <>
          "task page so a long, silent provisioning does not look " <>
          "like a frozen run."
      )
    end

    attribute :progress_at, :utc_datetime do
      allow_nil?(true)
      public?(true)
      description("When `progress_message` was last updated")
    end

    attribute :was_adopted, :boolean do
      allow_nil?(false)
      public?(true)
      default(false)

      description(
        "True if the Reconciler attached to an already-running " <>
          "container after a Camelot restart. UI hint: output log " <>
          "may be missing bytes that streamed before the restart."
      )
    end

    timestamps()
  end

  relationships do
    belongs_to :agent, Camelot.Agents.Agent do
      allow_nil?(false)
    end

    belongs_to :task, Camelot.Board.Task do
      allow_nil?(true)
      description("Nil for :bootstrap sessions")
    end

    belongs_to :user, Camelot.Accounts.User do
      allow_nil?(true)

      description(
        "Owner of the session — the task's creator for task-bound " <>
          "sessions, explicit for bootstrap sessions. Cached on the " <>
          "Session row so the pool and reconciler can index without " <>
          "joining through Task."
      )
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)
      accept([:kind, :bootstrap_kind, :retry_number])

      argument :agent_id, :uuid do
        allow_nil?(false)
      end

      argument :task_id, :uuid do
        allow_nil?(true)
      end

      argument :user_id, :uuid do
        allow_nil?(true)
      end

      change(manage_relationship(:agent_id, :agent, type: :append))
      change(manage_relationship(:task_id, :task, type: :append))
      change(manage_relationship(:user_id, :user, type: :append))
      change(set_attribute(:queued_at, &DateTime.utc_now/0))
      change(set_attribute(:status, :queued))
    end

    update :mark_running do
      accept([:service_id])
      change(set_attribute(:status, :running))
      change(set_attribute(:started_at, &DateTime.utc_now/0))
    end

    update :mark_adopted do
      accept([:service_id])
      change(set_attribute(:status, :running))
      change(set_attribute(:was_adopted, true))
    end

    update :complete do
      accept([
        :output_log,
        :exit_code,
        :error_message,
        :permission_denials,
        :cost_usd,
        :duration_ms,
        :duration_api_ms,
        :num_turns,
        :usage
      ])

      change(set_attribute(:status, :completed))
      change(set_attribute(:finished_at, &DateTime.utc_now/0))
    end

    update :fail do
      accept([
        :output_log,
        :exit_code,
        :error_message,
        :permission_denials,
        :cost_usd,
        :duration_ms,
        :duration_api_ms,
        :num_turns,
        :usage
      ])

      change(set_attribute(:status, :failed))
      change(set_attribute(:finished_at, &DateTime.utc_now/0))
    end

    update :cancel do
      change(set_attribute(:status, :cancelled))
      change(set_attribute(:finished_at, &DateTime.utc_now/0))
    end

    update :mark_empty do
      accept([
        :output_log,
        :exit_code,
        :error_message,
        :permission_denials,
        :cost_usd,
        :duration_ms,
        :duration_api_ms,
        :num_turns,
        :usage
      ])

      change(set_attribute(:status, :empty))
      change(set_attribute(:finished_at, &DateTime.utc_now/0))
    end

    update :report_progress do
      accept([:progress_phase, :progress_message])
      change(set_attribute(:progress_at, &DateTime.utc_now/0))
    end

    update :mark_clarified do
      accept([])
      change(set_attribute(:clarified, true))
    end

    update :annotate_error do
      accept([:error_message])
    end
  end
end
