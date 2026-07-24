defmodule Camelot.Agents.Agent do
  @moduledoc """
  An AI coding agent bound to a single project.

  Behaviour comes from `Camelot.Agents.AgentTemplate`
  (the `template` relationship). Each `*_override` column
  lets a project deviate from the template default
  without forking the template itself.
  """
  use Ash.Resource,
    domain: Camelot.Agents,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshOban],
    authorizers: [],
    simple_notifiers: [Camelot.Telemetry.Notifier]

  oban do
    scheduled_actions do
      schedule :dispatch_tasks, "* * * * *" do
        action(:dispatch_tasks)
        queue(:tasks)

        worker_module_name(Camelot.Agents.Agent.AshOban.ActionWorker.DispatchTasks)
      end
    end
  end

  postgres do
    table("agents")
    repo(Camelot.Repo)
  end

  attributes do
    uuid_primary_key(:id)

    attribute :name, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :status, :atom do
      allow_nil?(false)
      public?(true)
      default(:idle)
      constraints(one_of: [:idle, :busy])
    end

    attribute :max_retries, :integer do
      allow_nil?(false)
      public?(true)
      default(3)
    end

    attribute :command_prefix_override, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :executable_override, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :base_args_override, {:array, :string} do
      allow_nil?(true)
      public?(true)
    end

    attribute :env_vars_override, :map do
      allow_nil?(true)
      public?(true)
    end

    attribute :permission_args_by_stage_override, :map do
      allow_nil?(true)
      public?(true)
    end

    attribute :internal_tools_override, {:array, :string} do
      allow_nil?(true)
      public?(true)
    end

    attribute :base_retry_delay_ms_override, :integer do
      allow_nil?(true)
      public?(true)
    end

    timestamps()
  end

  relationships do
    belongs_to :project, Camelot.Projects.Project do
      allow_nil?(false)
    end

    belongs_to :user, Camelot.Accounts.User do
      allow_nil?(true)

      description(
        "Owner of the agent. Drives which profile volume " <>
          "mounts, which Swarm node hosts the runner, and " <>
          "which RunnerPool bucket counts the slot. " <>
          "Nullable for legacy rows; required for new agents."
      )
    end

    belongs_to :template, Camelot.Agents.AgentTemplate do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end

    has_many(:sessions, Camelot.Agents.Session)
  end

  identities do
    identity(:unique_project_user_template, [:project_id, :user_id, :template_id])
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)

      accept([
        :name,
        :template_id,
        :max_retries,
        :command_prefix_override,
        :executable_override,
        :base_args_override,
        :env_vars_override,
        :permission_args_by_stage_override,
        :internal_tools_override,
        :base_retry_delay_ms_override
      ])

      argument :project_id, :uuid do
        allow_nil?(false)
      end

      argument :user_id, :uuid do
        allow_nil?(false)
      end

      change(manage_relationship(:project_id, :project, type: :append))
      change(manage_relationship(:user_id, :user, type: :append))
    end

    update :update do
      primary?(true)

      accept([
        :name,
        :template_id,
        :max_retries,
        :command_prefix_override,
        :executable_override,
        :base_args_override,
        :env_vars_override,
        :permission_args_by_stage_override,
        :internal_tools_override,
        :base_retry_delay_ms_override
      ])
    end

    update :mark_busy do
      change(set_attribute(:status, :busy))
    end

    update :mark_idle do
      change(set_attribute(:status, :idle))
    end

    action :dispatch_tasks do
      run(Camelot.Agents.Changes.DispatchTasks)
    end
  end
end
