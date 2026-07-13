defmodule Camelot.Settings.SystemSetting do
  @moduledoc """
  Singleton row holding instance-wide defaults. Currently just
  the global fallback swarm node pin used by
  `Camelot.Runtime.AgentProcess.node_label_for/1` when neither a
  project nor its owner has one set.

  There is deliberately no `:create` action exposed for general
  use — the row is created lazily on first admin save via the
  upsert in `:set_default_swarm_node_label`, and the unique
  `:singleton` identity on `key` guarantees only one row can ever
  exist.
  """
  use Ash.Resource,
    domain: Camelot.Settings,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("system_settings")
    repo(Camelot.Repo)
  end

  attributes do
    uuid_primary_key(:id)

    attribute :key, :string do
      allow_nil?(false)
      default("singleton")
      writable?(false)
      public?(false)
    end

    attribute :default_swarm_node_label, :string do
      allow_nil?(true)
      public?(true)

      description(
        "Global fallback swarm node label used when neither a " <>
          "project nor its owner has a pin set. Containers run " <>
          "only on nodes matching `node.labels.camelot-home == <value>`."
      )
    end

    timestamps()
  end

  identities do
    identity(:singleton, [:key])
  end

  actions do
    defaults([:read])

    create :set_default_swarm_node_label do
      accept([:default_swarm_node_label])
      upsert?(true)
      upsert_identity(:singleton)
      upsert_fields([:default_swarm_node_label])
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if(always())
    end

    policy action(:set_default_swarm_node_label) do
      authorize_if(actor_attribute_equals(:role, :admin))
    end
  end
end
