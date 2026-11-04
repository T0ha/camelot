defmodule Camelot.Repo.Migrations.AddRecurrenceRules do
  @moduledoc """
  Adds the `recurrence_rules` table and the nullable
  `tasks.recurrence_rule_id` reference to it.

  Generated with `mix ash_postgres.generate_migrations`, then collapsed
  into a single `create table` plus one `alter table(:tasks)`.
  """

  use Ecto.Migration

  def up do
    create table(:recurrence_rules, primary_key: false) do
      add :id, :uuid,
        null: false,
        default: fragment("gen_random_uuid()"),
        primary_key: true

      add :frequency, :text, null: false
      add :interval, :bigint, null: false, default: 1
      add :weekdays, {:array, :bigint}, null: false, default: []
      add :day_of_month, :bigint
      add :time_of_day, :time, null: false
      add :time_zone, :text, null: false, default: "Etc/UTC"
      add :ends_at, :utc_datetime_usec
      add :enabled, :boolean, null: false, default: true
      add :skip_planning, :boolean, null: false, default: false
      add :next_run_at, :utc_datetime_usec

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :creator_id,
          references(:users,
            column: :id,
            name: "recurrence_rules_creator_id_fkey",
            type: :uuid,
            prefix: "public"
          ),
          null: false

      add :project_id,
          references(:projects,
            column: :id,
            name: "recurrence_rules_project_id_fkey",
            type: :uuid,
            prefix: "public"
          ),
          null: false
    end

    alter table(:tasks) do
      add :recurrence_rule_id,
          references(:recurrence_rules,
            column: :id,
            name: "tasks_recurrence_rule_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :nilify_all
          )
    end

    create index(:tasks, [:recurrence_rule_id])
  end

  def down do
    drop_if_exists index(:tasks, [:recurrence_rule_id])

    alter table(:tasks) do
      remove :recurrence_rule_id
    end

    drop table(:recurrence_rules)
  end
end
