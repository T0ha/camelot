defmodule Camelot.Board.Task do
  @moduledoc """
  A kanban task card with stage/state machine.

  Stage = board column (workflow phase):
    draft → todo → planning → executing → pr → done
    Any stage → cancelled

  State = card condition within a stage:
    queued, in_progress, waiting_for_input, error
    (nil for terminal stages: done, cancelled)
  """
  use Ash.Resource,
    domain: Camelot.Board,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshOban],
    authorizers: [],
    simple_notifiers: [Camelot.Telemetry.Notifier]

  alias Camelot.Board.Notifiers.NotifyTaskStateEmail

  @stages [
    :draft,
    :todo,
    :planning,
    :executing,
    :pr,
    :done,
    :cancelled
  ]

  @states [:queued, :waiting_for_input, :in_progress, :error]

  oban do
    scheduled_actions do
      schedule :dispatch_tasks, "* * * * *" do
        action(:dispatch_tasks)
        queue(:tasks)

        worker_module_name(Camelot.Board.Task.AshOban.ActionWorker.DispatchTasks)
      end
    end

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
              stage == :pr
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

    attribute :full_plan, :string do
      allow_nil?(true)
      public?(true)

      description(
        "Complete plan document fetched from the plan file the agent " <>
          "wrote in its workspace (~/.claude/plans/). `plan` holds " <>
          "whatever the agent returned inline, which may be only a " <>
          "pointer to that file plus a summary."
      )
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

    attribute :pr_comments_seen_at, :utc_datetime do
      allow_nil?(true)
      public?(true)
    end

    attribute :pr_auto_fix_attempts, :integer do
      allow_nil?(false)
      public?(true)
      default(0)

      description(
        "Consecutive automatic PR fix re-dispatches (merge conflict / " <>
          "CI failure). Capped so a task the agent cannot fix stops " <>
          "looping; reset on explicit human feedback."
      )
    end

    attribute :allowed_tools, {:array, :string} do
      allow_nil?(false)
      public?(true)
      default([])
    end

    attribute :stage, :atom do
      allow_nil?(false)
      public?(true)
      default(:todo)
      constraints(one_of: @stages)
    end

    attribute :state, :atom do
      allow_nil?(true)
      public?(true)
      default(:queued)
      constraints(one_of: @states)
    end

    attribute :runner_handle, :string do
      allow_nil?(true)
      public?(false)

      description(
        "Backend-specific identifier for the long-lived task runner — " <>
          "Swarm service id or DockerEngine container id. " <>
          "Set on first session of the task, cleared when the task " <>
          "reaches :done or :cancelled."
      )
    end

    attribute :last_error, :string do
      allow_nil?(true)
      public?(true)

      description(
        "Human-readable reason the task last entered the :error state — " <>
          "e.g. the runner container's log tail when a git clone fails. " <>
          "Surfaced on the board card so the user can fix the cause. " <>
          "Cleared when work resumes (begin_work/retry/reset)."
      )
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
    has_many(:messages, Camelot.Board.TaskMessage)
    has_many(:attachments, Camelot.Board.TaskAttachment)
  end

  aggregates do
    exists :waiting_for_slot?, :sessions do
      public?(true)
      filter(expr(status == :queued))

      description(
        "True while one of this task's sessions sits in the " <>
          "`Camelot.Runtime.RunnerPool` queue. Dispatch flips a task to " <>
          "`:in_progress` before its session asks for a slot, so an " <>
          "`:in_progress` task is not necessarily executing — it may be " <>
          "waiting for its creator to drop under `per_user_max`."
      )
    end
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

      argument :agent_id, :uuid do
        allow_nil?(false)
      end

      change(manage_relationship(:project_id, :project, type: :append))
      change(manage_relationship(:creator_id, :creator, type: :append))
      change(manage_relationship(:agent_id, :agent, type: :append))
    end

    update :update do
      primary?(true)
      accept([:title, :description, :priority])
    end

    update :set_runner_handle do
      accept([:runner_handle])

      validate(present(:runner_handle))
    end

    update :clear_runner_handle do
      accept([])

      change(set_attribute(:runner_handle, nil))
    end

    update :move_to_todo do
      accept([])

      validate(attribute_equals(:stage, :draft))
      change(set_attribute(:stage, :todo))
      change(set_attribute(:state, :queued))
    end

    update :begin_work do
      accept([])
      require_atomic?(false)

      validate(attribute_equals(:state, :queued))

      validate(fn changeset, _context ->
        stage = Ash.Changeset.get_attribute(changeset, :stage)

        if stage in [:todo, :planning, :executing, :pr] do
          :ok
        else
          {:error, field: :stage, message: "must be todo, planning, executing, or pr"}
        end
      end)

      change(fn changeset, _context ->
        stage = Ash.Changeset.get_attribute(changeset, :stage)

        changeset =
          if stage == :todo do
            Ash.Changeset.force_change_attribute(
              changeset,
              :stage,
              :planning
            )
          else
            changeset
          end

        changeset =
          Ash.Changeset.force_change_attribute(
            changeset,
            :state,
            :in_progress
          )

        Ash.Changeset.force_change_attribute(changeset, :last_error, nil)
      end)
    end

    update :submit_plan do
      accept([:plan, :full_plan])
      notifiers([NotifyTaskStateEmail])

      validate(attribute_equals(:stage, :planning))
      validate(attribute_equals(:state, :in_progress))
      validate(present(:plan))
      change(set_attribute(:state, :waiting_for_input))
    end

    update :approve_plan do
      accept([])

      validate(attribute_equals(:stage, :planning))
      validate(attribute_equals(:state, :waiting_for_input))
      validate(present(:plan))
      change(set_attribute(:stage, :executing))
      change(set_attribute(:state, :queued))
    end

    update :request_plan_changes do
      accept([])

      validate(attribute_equals(:stage, :planning))
      validate(attribute_equals(:state, :waiting_for_input))
      change(set_attribute(:state, :queued))
    end

    update :request_input do
      accept([])
      notifiers([NotifyTaskStateEmail])

      validate(attribute_equals(:state, :in_progress))
      change(set_attribute(:state, :waiting_for_input))
    end

    update :provide_input do
      accept([:allowed_tools])

      validate(attribute_equals(:state, :waiting_for_input))
      change(set_attribute(:state, :queued))
    end

    update :mark_error do
      accept([:last_error])
      notifiers([NotifyTaskStateEmail])

      change(set_attribute(:state, :error))
    end

    update :mark_runner_lost do
      accept([:last_error])
      notifiers([NotifyTaskStateEmail])

      change(set_attribute(:state, :error))
      change(set_attribute(:runner_handle, nil))
    end

    update :mark_in_progress do
      accept([])

      change(set_attribute(:state, :in_progress))
    end

    update :retry do
      accept([])

      validate(attribute_equals(:state, :error))
      change(set_attribute(:state, :queued))
      change(set_attribute(:last_error, nil))
    end

    update :reset do
      accept([])
      require_atomic?(false)

      validate(fn changeset, _ctx ->
        stage = Ash.Changeset.get_attribute(changeset, :stage)

        if stage in [:todo, :planning, :executing, :pr] do
          :ok
        else
          {:error, field: :stage, message: "cannot reset task in stage #{inspect(stage)}"}
        end
      end)

      change(set_attribute(:state, :queued))
      change(set_attribute(:last_error, nil))
    end

    update :pr_created do
      accept([:pr_url, :pr_number])
      notifiers([NotifyTaskStateEmail])

      validate(attribute_equals(:stage, :executing))
      validate(attribute_equals(:state, :in_progress))
      change(set_attribute(:stage, :pr))
      change(set_attribute(:state, :waiting_for_input))
    end

    update :request_pr_changes do
      accept([:pr_comments_seen_at, :pr_auto_fix_attempts])

      validate(attribute_equals(:stage, :pr))
      validate(attribute_equals(:state, :waiting_for_input))
      change(set_attribute(:state, :queued))
    end

    update :complete do
      accept([])
      notifiers([NotifyTaskStateEmail])

      validate(attribute_equals(:stage, :pr))
      validate(attribute_equals(:state, :waiting_for_input))
      change(set_attribute(:stage, :done))
      change(set_attribute(:state, nil))
    end

    update :cancel do
      accept([])

      change(set_attribute(:stage, :cancelled))
      change(set_attribute(:state, nil))
    end

    update :check_pr_status do
      accept([])
      require_atomic?(false)

      change(Camelot.Board.Changes.CheckPrStatus)
    end

    action :dispatch_tasks do
      run(Camelot.Board.Changes.DispatchTasks)
    end
  end

  @doc """
  Returns all valid task stages.
  """
  @spec stages() :: [atom()]
  def stages, do: @stages

  @doc """
  Returns all valid task states.
  """
  @spec states() :: [atom()]
  def states, do: @states

  @doc """
  Returns stages displayed as kanban columns.
  """
  @spec column_stages() :: [atom()]
  def column_stages do
    @stages -- [:cancelled, :draft]
  end
end
