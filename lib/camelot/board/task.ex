defmodule Camelot.Board.Task do
  @moduledoc """
  A kanban task card with state machine transitions.

  Status flow:
    created → planning → plan_review → executing →
    pr_created → pr_review → done
                          ↘ pr_fix → executing
    Any state → cancelled
  """
  use Ash.Resource,
    domain: Camelot.Board,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshOban],
    authorizers: []

  @statuses [
    :created,
    :planning,
    :plan_review,
    :executing,
    :pr_created,
    :pr_review,
    :pr_fix,
    :done,
    :cancelled
  ]

  oban do
    triggers do
      trigger :check_pr_status do
        action(:check_pr_status)
        scheduler_cron("*/2 * * * *")
        queue(:github)
        max_attempts(3)

        worker_module_name(Camelot.Board.Task.AshOban.Trigger.CheckPrStatus)

        scheduler_module_name(Camelot.Board.Task.AshOban.Scheduler.CheckPrStatus)

        where(
          expr(
            not is_nil(pr_number) and
              status in [
                :pr_created,
                :pr_review,
                :pr_fix
              ]
          )
        )
      end
    end
  end

  postgres do
    table("tasks")
    repo(Camelot.Repo)
  end

  attributes do
    uuid_primary_key(:id)

    attribute :title, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :description, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :plan, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :pr_url, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :pr_number, :integer do
      allow_nil?(true)
      public?(true)
    end

    attribute :priority, :integer do
      allow_nil?(false)
      public?(true)
      default(0)
    end

    attribute :status, :atom do
      allow_nil?(false)
      public?(true)
      default(:created)
      constraints(one_of: @statuses)
    end

    timestamps()
  end

  relationships do
    belongs_to :project, Camelot.Projects.Project do
      allow_nil?(false)
    end

    belongs_to :agent, Camelot.Agents.Agent do
      allow_nil?(true)
    end

    belongs_to :creator, Camelot.Accounts.User do
      allow_nil?(false)
    end

    has_many(:sessions, Camelot.Agents.Session)
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)
      accept([:title, :description, :priority])

      argument :project_id, :uuid do
        allow_nil?(false)
      end

      argument :creator_id, :uuid do
        allow_nil?(false)
      end

      change(manage_relationship(:project_id, :project, type: :append))
      change(manage_relationship(:creator_id, :creator, type: :append))
    end

    update :update do
      primary?(true)
      accept([:title, :description, :priority])
    end

    update :start_planning do
      accept([])

      validate(attribute_equals(:status, :created))
      change(set_attribute(:status, :planning))
    end

    update :submit_plan do
      accept([:plan])

      validate(attribute_equals(:status, :planning))
      change(set_attribute(:status, :plan_review))
    end

    update :approve_plan do
      accept([])

      validate(attribute_equals(:status, :plan_review))
      change(set_attribute(:status, :executing))
    end

    update :reject_plan do
      accept([])

      validate(attribute_equals(:status, :plan_review))
      change(set_attribute(:status, :planning))
    end

    update :pr_created do
      accept([:pr_url, :pr_number])

      validate(attribute_equals(:status, :executing))
      change(set_attribute(:status, :pr_created))
    end

    update :submit_pr_review do
      accept([])

      validate(attribute_equals(:status, :pr_created))
      change(set_attribute(:status, :pr_review))
    end

    update :approve_pr do
      accept([])

      validate(attribute_equals(:status, :pr_review))
      change(set_attribute(:status, :done))
    end

    update :request_pr_changes do
      accept([])

      validate(attribute_equals(:status, :pr_review))
      change(set_attribute(:status, :pr_fix))
    end

    update :start_pr_fix do
      accept([])

      validate(attribute_equals(:status, :pr_fix))
      change(set_attribute(:status, :executing))
    end

    update :assign_agent do
      accept([])
      require_atomic?(false)

      argument :agent_id, :uuid do
        allow_nil?(false)
      end

      change(manage_relationship(:agent_id, :agent, type: :append))
    end

    update :cancel do
      accept([])

      change(set_attribute(:status, :cancelled))
    end

    update :check_pr_status do
      accept([])
      require_atomic?(false)

      change(Camelot.Board.Changes.CheckPrStatus)
    end
  end

  @doc """
  Returns all valid task statuses.
  """
  @spec statuses() :: [atom()]
  def statuses, do: @statuses

  @doc """
  Returns statuses displayed as kanban columns.
  """
  @spec column_statuses() :: [atom()]
  def column_statuses do
    [
      :created,
      :planning,
      :plan_review,
      :executing,
      :pr_created,
      :pr_review,
      :pr_fix,
      :done
    ]
  end
end
