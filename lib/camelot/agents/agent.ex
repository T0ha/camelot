defmodule Camelot.Agents.Agent do
  @moduledoc """
  An AI coding agent bound to a single project.
  Runs a CLI tool (Claude Code or Codex) to execute tasks.
  """
  use Ash.Resource,
    domain: Camelot.Agents,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshOban],
    authorizers: []

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

    attribute :type, :atom do
      allow_nil?(false)
      public?(true)
      constraints(one_of: [:claude_code, :codex])
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

    timestamps()
  end

  relationships do
    belongs_to :project, Camelot.Projects.Project do
      allow_nil?(false)
    end

    has_many(:sessions, Camelot.Agents.Session)
  end

  identities do
    identity(:unique_project, [:project_id])
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)
      accept([:name, :type, :max_retries])

      argument :project_id, :uuid do
        allow_nil?(false)
      end

      change(manage_relationship(:project_id, :project, type: :append))
    end

    update :update do
      primary?(true)
      accept([:name, :type, :max_retries])
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
