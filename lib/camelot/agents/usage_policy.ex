defmodule Camelot.Agents.UsagePolicy do
  @moduledoc """
  A user's scheduling preferences for one agent CLI: how much of the
  provider's weekly quota cards may use, and when they may run.

  * `weekly_cap_percent` — stop dispatching once the latest weekly
    `Camelot.Agents.UsageSnapshot` reaches this percentage, keeping
    the rest for manual use. `nil` means no cap.
  * `windows` — UTC `Camelot.Agents.RunWindow`s cards may start in.
    Empty means any time.

  No row means no restriction. Both can be overridden per card
  (`Camelot.Board.Task.weekly_cap_override`/`windows_override`); the
  decision itself is `Camelot.Scheduling.Gate`.
  """
  use Ash.Resource,
    domain: Camelot.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: []

  alias Camelot.Agents.RunWindow

  postgres do
    table("usage_policies")
    repo(Camelot.Repo)

    references do
      reference(:user, on_delete: :delete)
      reference(:agent, on_delete: :delete)
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :weekly_cap_percent, :integer do
      allow_nil?(true)
      public?(true)
      constraints(min: 1, max: 100)
      description("Stop dispatching at this weekly usage %; nil = no cap")
    end

    attribute :windows, {:array, RunWindow} do
      allow_nil?(false)
      public?(true)
      default([])
      description("UTC minute-of-week ranges cards may start in; [] = any time")
    end

    timestamps()
  end

  relationships do
    belongs_to :user, Camelot.Accounts.User do
      allow_nil?(false)
      public?(true)
    end

    belongs_to :agent, Camelot.Agents.Agent do
      allow_nil?(false)
      public?(true)
    end
  end

  identities do
    identity(:unique_user_agent, [:user_id, :agent_id])
  end

  actions do
    defaults([:read, :destroy])

    create :upsert do
      primary?(true)
      accept([:weekly_cap_percent, :windows, :user_id, :agent_id])
      upsert?(true)
      upsert_identity(:unique_user_agent)
      upsert_fields([:weekly_cap_percent, :windows, :updated_at])
    end

    read :for_user do
      argument :user_id, :uuid do
        allow_nil?(false)
      end

      filter(expr(user_id == ^arg(:user_id)))
    end
  end
end
