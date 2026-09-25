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

  alias Camelot.Agents.Agent
  alias Camelot.Board.Notifiers.NotifyTaskStateEmail
  alias Camelot.Board.Task.Changes.RejectBlocked
  alias Camelot.Board.TaskLink

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

  # Stages from which work can be (re)started: the dispatcher picks a
  # `:queued` task up again and resumes it from wherever it left off.
  @resumable_stages [:todo, :planning, :executing, :pr]

  # A blocker stops gating as soon as it has a PR open — the dependent
  # then has a real branch to build on and does not have to wait for
  # human review to finish.
  @blocking_stages @stages -- [:pr, :done, :cancelled]

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
              stage == :pr and
              project.status == :active
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

    attribute :interrupt_requeues, :integer do
      allow_nil?(false)
      public?(true)
      default(0)

      description(
        "Consecutive automatic re-queues after the runner was interrupted " <>
          "by infrastructure (a deploy replacing the runner container, a " <>
          "lost Swarm service). Capped so a task that can never run stops " <>
          "looping and errors instead; reset on any forward progress."
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

    attribute :next_model, :string do
      allow_nil?(true)
      public?(true)

      description(
        "Sticky, explicit model choice for the next dispatch. Nil " <>
          "resolves to the agent's default_model; once set, it stays " <>
          "until the user changes it again — it is never cleared or " <>
          "overwritten by the system after a run."
      )
    end

    timestamps()
  end

  relationships do
    belongs_to :project, Camelot.Projects.Project do
      allow_nil?(false)
    end

    belongs_to :agent, Agent do
      allow_nil?(true)
    end

    belongs_to :creator, Camelot.Accounts.User do
      allow_nil?(false)
    end

    has_many :sessions, Camelot.Agents.Session do
      sort(inserted_at: :desc)
    end

    has_many :messages, Camelot.Board.TaskMessage do
      sort(inserted_at: :desc)
    end

    has_many(:attachments, Camelot.Board.TaskAttachment)

    # Raw link rows, both directions.
    has_many :outgoing_links, TaskLink do
      destination_attribute(:source_task_id)
    end

    has_many :incoming_links, TaskLink do
      destination_attribute(:target_task_id)
    end

    # Per-type filtered join relationships. `many_to_many` has no
    # filter that reaches the join table, but Ash reuses a
    # pre-declared `join_relationship` verbatim — filter included.
    has_many :blocker_links, TaskLink do
      destination_attribute(:target_task_id)
      filter(expr(link_type == :blocks))
    end

    has_many :blocked_task_links, TaskLink do
      destination_attribute(:source_task_id)
      filter(expr(link_type == :blocks))
    end

    has_many :subtask_links, TaskLink do
      destination_attribute(:source_task_id)
      filter(expr(link_type == :parent_of))
    end

    has_many :related_out_links, TaskLink do
      destination_attribute(:source_task_id)
      filter(expr(link_type == :relates_to))
    end

    has_many :related_in_links, TaskLink do
      destination_attribute(:target_task_id)
      filter(expr(link_type == :relates_to))
    end

    has_one :parent_link, TaskLink do
      destination_attribute(:target_task_id)
      from_many?(true)
      filter(expr(link_type == :parent_of))
    end

    many_to_many :blockers, __MODULE__ do
      through(TaskLink)
      join_relationship(:blocker_links)
      source_attribute_on_join_resource(:target_task_id)
      destination_attribute_on_join_resource(:source_task_id)
    end

    many_to_many :blocked_tasks, __MODULE__ do
      through(TaskLink)
      join_relationship(:blocked_task_links)
      source_attribute_on_join_resource(:source_task_id)
      destination_attribute_on_join_resource(:target_task_id)
    end

    many_to_many :subtasks, __MODULE__ do
      through(TaskLink)
      join_relationship(:subtask_links)
      source_attribute_on_join_resource(:source_task_id)
      destination_attribute_on_join_resource(:target_task_id)
    end

    many_to_many :related_out_tasks, __MODULE__ do
      through(TaskLink)
      join_relationship(:related_out_links)
      source_attribute_on_join_resource(:source_task_id)
      destination_attribute_on_join_resource(:target_task_id)
    end

    many_to_many :related_in_tasks, __MODULE__ do
      through(TaskLink)
      join_relationship(:related_in_links)
      source_attribute_on_join_resource(:target_task_id)
      destination_attribute_on_join_resource(:source_task_id)
    end
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

    exists :blocked_by_blockers?, :incoming_links do
      public?(true)
      filter(expr(link_type == :blocks and source_task.stage in ^@blocking_stages))

      description(
        "True while a `:blocks` predecessor has not yet reached " <>
          "`:pr`/`:done`/`:cancelled`."
      )
    end

    exists :blocked_by_subtasks?, :outgoing_links do
      public?(true)
      filter(expr(link_type == :parent_of and target_task.stage in ^@blocking_stages))

      description(
        "True while any subtask (`:parent_of` target) has not yet " <>
          "reached `:pr`/`:done`/`:cancelled`. A parent task is " <>
          "treated as blocked while any subtask is still pre-PR — drop " <>
          "this aggregate from `blocked?` if parents should run freely."
      )
    end
  end

  calculations do
    calculate :blocked?, :boolean, expr(blocked_by_blockers? or blocked_by_subtasks?) do
      public?(true)

      description(
        "Recomputed on every read from the two gating aggregates, so " <>
          "a blocker reaching `:pr` frees its dependents on the very " <>
          "next dispatch tick with no extra bookkeeping."
      )
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)
      accept([:title, :description, :priority, :next_model])

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

      validate(fn changeset, _context ->
        validate_next_model(changeset, Ash.Changeset.get_argument(changeset, :agent_id))
      end)
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

    update :set_next_model do
      accept([:next_model])
      require_atomic?(false)

      validate(fn changeset, _context ->
        validate_next_model(changeset, changeset.data.agent_id)
      end)
    end

    update :begin_work do
      accept([])
      require_atomic?(false)

      validate(attribute_equals(:state, :queued))

      validate(fn changeset, _context ->
        stage = Ash.Changeset.get_attribute(changeset, :stage)

        if stage in @resumable_stages do
          :ok
        else
          {:error, field: :stage, message: "must be todo, planning, executing, or pr"}
        end
      end)

      # A plain `validate` can't see aggregates/calculations, so the
      # blocked check runs as a `before_action` hook instead — guards a
      # manual Retry/Reset from jumping the gate the same way the
      # dispatcher's `not blocked?` query filter does.
      change(RejectBlocked)

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
      change(set_attribute(:interrupt_requeues, 0))
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
      change(set_attribute(:interrupt_requeues, 0))
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

    # Recovery from an infrastructure interruption (a deploy replacing the
    # runner container, a Swarm service that vanished) rather than from
    # anything the agent did. The task goes straight back to `:queued` so
    # the every-minute `dispatch_tasks` cron resumes it from its current
    # stage, and `runner_handle` is dropped so a clean runner is built.
    # Deliberately notifier-free: a deploy must not email every user.
    update :requeue_interrupted do
      accept([])
      require_atomic?(false)

      # A runner whose container was merely *replaced* (an image roll)
      # still has a healthy service behind it, so its handle is worth
      # keeping — recreating the service would throw away a container
      # that is already up. A runner that was *lost* has no usable
      # handle, and leaving it set would send the next dispatch at a
      # dead service.
      argument :keep_runner_handle, :boolean do
        allow_nil?(false)
        default(false)
      end

      validate(fn changeset, _ctx ->
        stage = Ash.Changeset.get_attribute(changeset, :stage)

        if stage in @resumable_stages do
          :ok
        else
          {:error, field: :stage, message: "cannot resume stage #{inspect(stage)}"}
        end
      end)

      change(set_attribute(:state, :queued))
      change(set_attribute(:last_error, nil))

      change(fn changeset, _ctx ->
        current = Ash.Changeset.get_data(changeset, :interrupt_requeues) || 0

        changeset
        |> Ash.Changeset.force_change_attribute(:interrupt_requeues, current + 1)
        |> maybe_clear_runner_handle()
      end)
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

        if stage in @resumable_stages do
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
      change(set_attribute(:interrupt_requeues, 0))
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
      change(set_attribute(:interrupt_requeues, 0))
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
  Returns the stages a `:blocks`/`:parent_of` link still gates on —
  everything before `:pr` (a blocker's PR is enough for its dependent
  to build on) and short of the terminal `:done`/`:cancelled`.
  """
  @spec blocking_stages() :: [atom()]
  def blocking_stages, do: @blocking_stages

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

  @doc """
  Returns all valid task link types (`:blocks`, `:parent_of`,
  `:relates_to`). Delegates to `Camelot.Board.TaskLink.link_types/0` so
  the two modules can't drift apart.
  """
  @spec link_types() :: [atom()]
  def link_types, do: TaskLink.link_types()

  @doc """
  The umbrella task this task is a subtask of, or `nil`.

  `:parent` cannot be a `many_to_many` — `Ash.Resource.Relationships.ManyToMany`
  hardcodes `cardinality: :many` — so this reads `parent_link.source_task`
  instead. Requires `parent_link: :source_task` to be loaded.
  """
  @spec parent(t()) :: t() | nil
  def parent(%{parent_link: %TaskLink{source_task: task}}), do: task
  def parent(_task), do: nil

  @doc """
  Every `:relates_to` counterpart, in either direction.

  Requires `:related_out_tasks` and `:related_in_tasks` to be loaded;
  an unloaded task has no known counterparts rather than raising, so
  that `PromptBuilder.related_context_block/1` degrades to an empty
  block the same way its blocker and subtask sections do.
  """
  @spec related_tasks(t()) :: [t()]
  def related_tasks(%{related_out_tasks: %Ash.NotLoaded{}}), do: []
  def related_tasks(%{related_in_tasks: %Ash.NotLoaded{}}), do: []

  def related_tasks(%{related_out_tasks: out_tasks, related_in_tasks: in_tasks}) do
    out_tasks ++ in_tasks
  end

  @doc """
  Load spec for the task-link associations `PromptBuilder.build/1`
  needs (blockers with their project, for the stacked-branch directive
  and blocker context; parent, subtasks and related tasks for the rest
  of the context block). Shared by
  `Camelot.Board.Changes.DispatchTasks.dispatchable_tasks/0` and
  `Camelot.Runtime.TaskRunner.start_adoption/2` so both loaders that
  call `PromptBuilder.build/1` load the same associations.
  """
  @spec link_load() :: keyword()
  def link_load do
    [
      blockers: [:project],
      subtasks: [:project],
      related_out_tasks: [:project],
      related_in_tasks: [:project],
      parent_link: [source_task: [:project]]
    ]
  end

  # Rejects a `next_model` that isn't one of the agent's configured
  # `available_models`, so a typo never reaches the CLI. An agent with no
  # `available_models` configured (or none loadable) imposes no
  # restriction — the flag-less/unconfigured CLI case.
  defp validate_next_model(changeset, agent_id) do
    case Ash.Changeset.get_attribute(changeset, :next_model) do
      nil -> :ok
      model -> agent_id |> load_agent() |> validate_model_allowed(model)
    end
  end

  defp load_agent(nil), do: nil

  defp load_agent(agent_id) do
    case Ash.get(Agent, agent_id, authorize?: false) do
      {:ok, agent} -> agent
      {:error, _} -> nil
    end
  end

  defp validate_model_allowed(nil, _model), do: :ok
  defp validate_model_allowed(%Agent{available_models: []}, _model), do: :ok

  defp validate_model_allowed(%Agent{available_models: models}, model) do
    if model in models do
      :ok
    else
      {:error, field: :next_model, message: "is not one of the agent's available models"}
    end
  end

  # Drops `runner_handle` unless the caller asked to keep it — see the
  # `keep_runner_handle` argument on `:requeue_interrupted`.
  defp maybe_clear_runner_handle(changeset) do
    if Ash.Changeset.get_argument(changeset, :keep_runner_handle) do
      changeset
    else
      Ash.Changeset.force_change_attribute(changeset, :runner_handle, nil)
    end
  end
end
