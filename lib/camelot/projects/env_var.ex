defmodule Camelot.Projects.EnvVar do
  @moduledoc """
  A scoped environment variable injected into a project's
  runner containers.

  Each row attaches to exactly one scope — a project, an
  agent, or a user — or to none, making it a global default.
  When the same `key` is defined at several scopes for a
  given runner, the most specific wins in the order
  **project > agent > user > global** (see
  `Camelot.Runtime.EnvVarResolver`).

  Values are always encrypted at rest via `AshCloak` against
  `Camelot.Vault`, exactly like `Camelot.Accounts.Credential`.
  The `secret` flag does not affect storage — it only drives
  UI masking and log redaction for values the operator marks
  sensitive (passwords, tokens).
  """
  use Ash.Resource,
    domain: Camelot.Projects,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshCloak],
    authorizers: []

  alias Camelot.Projects.EnvVar.Validations.SingleScope

  postgres do
    table("env_vars")
    repo(Camelot.Repo)

    identity_wheres_to_sql(
      unique_global_key: "project_id IS NULL AND agent_id IS NULL AND user_id IS NULL",
      unique_project_key: "project_id IS NOT NULL",
      unique_agent_key: "agent_id IS NOT NULL",
      unique_user_key: "user_id IS NOT NULL"
    )
  end

  cloak do
    vault(Camelot.Vault)
    attributes([:value])
  end

  attributes do
    uuid_primary_key(:id)

    attribute :key, :string do
      allow_nil?(false)
      public?(true)

      constraints(match: ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/)
      description("Environment variable name, e.g. DATABASE_URL")
    end

    attribute :value, :string do
      allow_nil?(false)
      public?(true)
      sensitive?(true)
      description("Variable value, encrypted at rest via AshCloak")
    end

    attribute :secret, :boolean do
      allow_nil?(false)
      public?(true)
      default(false)

      description(
        "When true, the value is masked in the UI and redacted " <>
          "from logs. Storage is always encrypted regardless."
      )
    end

    timestamps()
  end

  relationships do
    belongs_to :project, Camelot.Projects.Project do
      allow_nil?(true)
      attribute_writable?(true)
      public?(true)
    end

    belongs_to :agent, Camelot.Agents.Agent do
      allow_nil?(true)
      attribute_writable?(true)
      public?(true)
    end

    belongs_to :user, Camelot.Accounts.User do
      allow_nil?(true)
      attribute_writable?(true)
      public?(true)
    end
  end

  identities do
    # One scope per row means every row has NULL in ≥2 scope columns,
    # and PostgreSQL (< 15) treats NULLs as distinct — so a single
    # composite unique index never fires. Instead, a partial unique
    # index per scope (via `where`) enforces "one value per key per
    # scope" correctly regardless of the NULL columns.
    identity :unique_global_key, [:key] do
      where(expr(is_nil(project_id) and is_nil(agent_id) and is_nil(user_id)))
    end

    identity :unique_project_key, [:key, :project_id] do
      where(expr(not is_nil(project_id)))
    end

    identity :unique_agent_key, [:key, :agent_id] do
      where(expr(not is_nil(agent_id)))
    end

    identity :unique_user_key, [:key, :user_id] do
      where(expr(not is_nil(user_id)))
    end
  end

  validations do
    validate(SingleScope)
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)
      accept([:key, :value, :secret, :project_id, :agent_id, :user_id])
    end

    update :update do
      primary?(true)
      accept([:key, :value, :secret])
      require_atomic?(false)
    end
  end
end
