defmodule Camelot.Agents.UsageSnapshot do
  @moduledoc """
  One reading of how much of a provider quota window an account has
  used. Append-only: the latest row for a key is authoritative.

  Keyed by the **credential** the reading belongs to, because both
  CLIs report the account's quota, not the agent's — two agents on
  one key must see the same numbers. A key supplied through an env
  var has no `Camelot.Accounts.Credential` row, so `credential_id` is
  then nil and the reading falls back to `user_id` + `credential_kind`
  (the same attribution `Credential.usage_limited_until` uses).

  `source` says where the number came from: `:cli` (parsed from the
  run's own output, see `Camelot.Runtime.RateLimitEvents`), `:manual`
  (typed on the profile page) or `:estimated` (a manual reading plus
  Camelot's own run time since — never stored, only computed by
  `Camelot.Agents.UsageSnapshots`).

  Lookups and the write path live in `Camelot.Agents.UsageSnapshots`.
  Pruning old rows is out of scope for now.
  """
  use Ash.Resource,
    domain: Camelot.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [],
    simple_notifiers: [Camelot.Telemetry.Notifier]

  alias Camelot.Accounts.Credential

  @windows [:weekly, :session]
  @sources [:cli, :manual, :estimated]

  postgres do
    table("usage_snapshots")
    repo(Camelot.Repo)

    references do
      reference(:credential, on_delete: :delete)
      reference(:user, on_delete: :delete)
    end

    custom_indexes do
      index([:user_id, :credential_kind, :window, :observed_at])
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :credential_kind, :atom do
      allow_nil?(false)
      public?(true)
      constraints(one_of: Credential.valid_kinds())
    end

    attribute :window, :atom do
      allow_nil?(false)
      public?(true)
      constraints(one_of: @windows)
      description(":weekly (seven-day) or :session (five-hour) quota window")
    end

    attribute :used_percent, :float do
      allow_nil?(false)
      public?(true)
      constraints(min: 0.0, max: 100.0)
    end

    attribute :resets_at, :utc_datetime_usec do
      allow_nil?(false)
      public?(true)
      description("When the provider resets this window; past = stale")
    end

    attribute :source, :atom do
      allow_nil?(false)
      public?(true)
      constraints(one_of: @sources)
    end

    attribute :observed_at, :utc_datetime_usec do
      allow_nil?(false)
      public?(true)
    end

    create_timestamp(:inserted_at)
  end

  relationships do
    belongs_to :credential, Credential do
      allow_nil?(true)
      public?(true)
    end

    belongs_to :user, Camelot.Accounts.User do
      allow_nil?(false)
      public?(true)
    end
  end

  actions do
    defaults([:read, :destroy])

    create :record do
      primary?(true)

      accept([
        :credential_id,
        :user_id,
        :credential_kind,
        :window,
        :used_percent,
        :resets_at,
        :source,
        :observed_at
      ])
    end

    read :latest do
      argument :user_id, :uuid do
        allow_nil?(false)
      end

      argument :credential_kind, :atom do
        allow_nil?(false)
      end

      argument :credential_id, :uuid do
        allow_nil?(true)
      end

      argument :window, :atom do
        allow_nil?(false)
        constraints(one_of: @windows)
      end

      prepare(Camelot.Agents.UsageSnapshot.Preparations.Latest)
    end
  end
end
