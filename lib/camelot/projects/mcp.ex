defmodule Camelot.Projects.Mcp do
  @moduledoc """
  Per-project Model Context Protocol server definition.

  These are *additions* on top of whatever MCPs the
  runner image already bakes in. The entrypoint merges
  image defaults with this list at spawn time, resolving
  any `${credential:<kind>}` placeholders in `env`
  against the per-user Swarm secret at
  `/run/secrets/<kind>`.
  """
  use Ash.Resource,
    domain: Camelot.Projects,
    data_layer: AshPostgres.DataLayer,
    authorizers: []

  postgres do
    table("project_mcps")
    repo(Camelot.Repo)
  end

  attributes do
    uuid_primary_key(:id)

    attribute :name, :string do
      allow_nil?(false)
      public?(true)
      description("MCP identifier (e.g. `linear`, `slack`)")
    end

    attribute :command, :string do
      allow_nil?(false)
      public?(true)
      description("Executable launched by the MCP host")
    end

    attribute :args, {:array, :string} do
      allow_nil?(false)
      public?(true)
      default([])
    end

    attribute :env, :map do
      allow_nil?(false)
      public?(true)
      default(%{})

      description(
        "Env vars passed to the MCP process. Values may " <>
          "contain `${credential:<kind>}` placeholders that " <>
          "the entrypoint resolves at spawn time."
      )
    end

    timestamps()
  end

  relationships do
    belongs_to :project, Camelot.Projects.Project do
      allow_nil?(false)
    end
  end

  identities do
    identity(:unique_name_per_project, [:project_id, :name])
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)
      accept([:name, :command, :args, :env])

      argument :project_id, :uuid do
        allow_nil?(false)
      end

      change(manage_relationship(:project_id, :project, type: :append))
    end

    update :update do
      primary?(true)
      accept([:name, :command, :args, :env])
    end
  end
end
