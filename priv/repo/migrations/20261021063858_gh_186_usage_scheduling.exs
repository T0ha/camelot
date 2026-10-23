defmodule Camelot.Repo.Migrations.Gh186UsageScheduling do
  @moduledoc """
  GH#186 usage-aware scheduling: per-user time zone, usage policies and
  snapshots, per-card schedule fields, and the stage a session ran for.

  Generated with `mix ash.codegen`. The `agents` snapshot it also wrote
  only catches up with `models_probe`, which
  `20261009090000_agent_models_probe.exs` already added by hand, so
  that column is deliberately not altered here.
  """

  use Ecto.Migration

  def up do
    alter table(:users) do
      add :time_zone, :text, null: false, default: "Etc/UTC"
    end

    create table(:usage_snapshots, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :credential_kind, :text, null: false
      add :window, :text, null: false
      add :used_percent, :float, null: false
      add :resets_at, :utc_datetime_usec, null: false
      add :source, :text, null: false
      add :observed_at, :utc_datetime_usec, null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :credential_id,
          references(:credentials,
            column: :id,
            name: "usage_snapshots_credential_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :delete_all
          )

      add :user_id,
          references(:users,
            column: :id,
            name: "usage_snapshots_user_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :delete_all
          ),
          null: false
    end

    create index(:usage_snapshots, [:user_id, :credential_kind, :window, :observed_at])

    create table(:usage_policies, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :weekly_cap_percent, :bigint
      add :windows, {:array, :map}, null: false, default: []

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :user_id,
          references(:users,
            column: :id,
            name: "usage_policies_user_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :delete_all
          ),
          null: false

      add :agent_id,
          references(:agents,
            column: :id,
            name: "usage_policies_agent_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :delete_all
          ),
          null: false
    end

    create unique_index(:usage_policies, [:user_id, :agent_id],
             name: "usage_policies_unique_user_agent_index"
           )

    alter table(:tasks) do
      add :weekly_cap_override, :bigint
      add :windows_override, {:array, :map}
      add :ignore_limits, :boolean, null: false, default: false
      add :start_at, :utc_datetime_usec
      add :deadline_at, :utc_datetime_usec
    end

    alter table(:sessions) do
      add :stage, :text
    end
  end

  def down do
    alter table(:sessions) do
      remove :stage
    end

    alter table(:tasks) do
      remove :deadline_at
      remove :start_at
      remove :ignore_limits
      remove :windows_override
      remove :weekly_cap_override
    end

    drop_if_exists unique_index(:usage_policies, [:user_id, :agent_id],
                     name: "usage_policies_unique_user_agent_index"
                   )

    drop constraint(:usage_policies, "usage_policies_user_id_fkey")

    drop constraint(:usage_policies, "usage_policies_agent_id_fkey")

    drop table(:usage_policies)

    drop constraint(:usage_snapshots, "usage_snapshots_credential_id_fkey")

    drop constraint(:usage_snapshots, "usage_snapshots_user_id_fkey")

    drop_if_exists index(:usage_snapshots, [:user_id, :credential_kind, :window, :observed_at])

    drop table(:usage_snapshots)

    alter table(:users) do
      remove :time_zone
    end
  end
end
