defmodule Camelot.Board.RecurrenceRule do
  @moduledoc """
  A recurring series of task cards — "repeat daily / weekly / monthly
  at HH:MM" — set from a card's Schedule menu.

  A series has at most **one active card** at a time. Each card is an
  ordinary `Camelot.Board.Task` pinned to the occurrence with
  `start_at` (so `Camelot.Scheduling.Gate` holds it until then, and it
  stays editable until it starts). Once that card reaches `:done` or
  `:cancelled`, the `:spawn_next` trigger creates the next card for the
  first occurrence **after now**, copied from the latest card in the
  series — so a run is skipped while the previous card is still open,
  and a series that was idle for a while gets one card, not a backlog.

  Occurrences are local wall-clock times in `time_zone`; see
  `Camelot.Scheduling.Recurrence`. Turning Repeat off (`:disable`)
  keeps the rule and its cards.
  """
  use Ash.Resource,
    domain: Camelot.Board,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshOban],
    authorizers: [],
    simple_notifiers: [Camelot.Telemetry.Notifier]

  alias Camelot.Accounts.User.Validations.KnownTimeZone
  alias Camelot.Board.RecurrenceRule.Changes.ComputeNextRun
  alias Camelot.Board.RecurrenceRule.Changes.SpawnNext
  alias Camelot.Board.RecurrenceRule.Changes.SyncUpcomingCard
  alias Camelot.Board.RecurrenceRule.Validations.ValidPattern

  @frequencies [:daily, :weekly, :monthly]

  @rule_fields [
    :frequency,
    :interval,
    :weekdays,
    :day_of_month,
    :time_of_day,
    :time_zone,
    :ends_at,
    :skip_planning
  ]

  oban do
    triggers do
      trigger :spawn_next do
        action(:spawn_next)
        scheduler_cron("* * * * *")
        queue(:tasks)
        max_attempts(3)

        worker_module_name(Camelot.Board.RecurrenceRule.AshOban.Trigger.SpawnNext)

        scheduler_module_name(Camelot.Board.RecurrenceRule.AshOban.Scheduler.SpawnNext)

        where(
          expr(
            enabled and project.status == :active and
              not exists(tasks, stage not in [:done, :cancelled])
          )
        )
      end
    end
  end

  postgres do
    table("recurrence_rules")
    repo(Camelot.Repo)
  end

  attributes do
    uuid_primary_key(:id)

    attribute :frequency, :atom do
      allow_nil?(false)
      public?(true)
      constraints(one_of: @frequencies)
    end

    attribute :interval, :integer do
      allow_nil?(false)
      public?(true)
      default(1)
      constraints(min: 1, max: 99)
      description("Every N days, weeks or months, counted from creation.")
    end

    attribute :weekdays, {:array, :integer} do
      allow_nil?(false)
      public?(true)
      default([])
      constraints(items: [min: 1, max: 7])
      description("Weekly rules: ISO weekdays, 1 = Monday.")
    end

    attribute :day_of_month, :integer do
      allow_nil?(true)
      public?(true)
      constraints(min: 1, max: 31)

      description(
        "Monthly rules: the day to run on, clamped to the last day of " <>
          "a shorter month."
      )
    end

    attribute :time_of_day, :time do
      allow_nil?(false)
      public?(true)
      description("Local wall-clock time in `time_zone`.")
    end

    attribute :time_zone, :string do
      allow_nil?(false)
      public?(true)
      default("Etc/UTC")
      description("Copied from the creator's `User.time_zone` on save.")
    end

    attribute :ends_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
      description("Repeat until: no card is spawned for a later occurrence.")
    end

    attribute :enabled, :boolean do
      allow_nil?(false)
      public?(true)
      default(true)
    end

    attribute :skip_planning, :boolean do
      allow_nil?(false)
      public?(true)
      default(false)
      description("Spawned cards start straight in execution.")
    end

    attribute :next_run_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)

      description(
        "The occurrence the series' upcoming card is pinned to. Nil " <>
          "while disabled."
      )
    end

    timestamps()
  end

  relationships do
    belongs_to :creator, Camelot.Accounts.User do
      allow_nil?(false)
    end

    belongs_to :project, Camelot.Projects.Project do
      allow_nil?(false)
    end

    has_many(:tasks, Camelot.Board.Task)
  end

  actions do
    defaults([:read, :destroy])

    # Starts a series from an existing card (`task_id`), which becomes
    # its first card — pinned to the first occurrence if it has not
    # started yet.
    create :create do
      primary?(true)
      accept(@rule_fields)

      argument :task_id, :uuid do
        allow_nil?(false)
      end

      argument :creator_id, :uuid do
        allow_nil?(false)
      end

      change(manage_relationship(:creator_id, :creator, type: :append))

      validate(KnownTimeZone)
      validate(ValidPattern)
      change(ComputeNextRun)
      change(SyncUpcomingCard)
    end

    # Saving a repeat turns it back on, and moves a not-yet-started
    # upcoming card to the new first occurrence.
    update :update do
      primary?(true)
      accept(@rule_fields)
      require_atomic?(false)

      validate(KnownTimeZone)
      validate(ValidPattern)
      change(set_attribute(:enabled, true))
      change(ComputeNextRun)
      change(SyncUpcomingCard)
    end

    update :disable do
      accept([])

      change(set_attribute(:enabled, false))
      change(set_attribute(:next_run_at, nil))
    end

    update :spawn_next do
      accept([])
      require_atomic?(false)

      change(SpawnNext)
    end
  end
end
