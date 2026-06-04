defmodule Camelot.Accounts.Credential do
  @moduledoc """
  An encrypted credential belonging to a user — API key,
  OAuth token, GitHub PAT, or SSH key — used by runner
  containers to authenticate against external services.

  Values are encrypted at rest via `AshCloak` against
  `Camelot.Vault`. The encryption key comes from the
  `ENCRYPTION_KEY` env var in production (fail-hard if
  missing); dev/test use a stable key from `config/*.exs`.
  """
  use Ash.Resource,
    domain: Camelot.Accounts,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshCloak],
    authorizers: []

  @kinds [
    :claude_api_key,
    :openai_api_key,
    :codex_api_key,
    :github_pat,
    :github_oauth,
    :ssh_private_key,
    :generic
  ]

  postgres do
    table("credentials")
    repo(Camelot.Repo)
  end

  cloak do
    vault(Camelot.Vault)
    attributes([:value])
  end

  attributes do
    uuid_primary_key(:id)

    attribute :kind, :atom do
      allow_nil?(false)
      public?(true)
      constraints(one_of: @kinds)
      description("Credential type — drives where it's mounted in the runner")
    end

    attribute :name, :string do
      allow_nil?(true)
      public?(true)
      description("Optional label, useful for :generic")
    end

    attribute :value, :string do
      allow_nil?(false)
      public?(true)
      sensitive?(true)
      description("Secret value, encrypted at rest via AshCloak")
    end

    attribute :metadata, :map do
      allow_nil?(false)
      public?(true)
      default(%{})
      description("Non-secret context (e.g. OAuth expiry, key fingerprint)")
    end

    timestamps()
  end

  relationships do
    belongs_to :user, Camelot.Accounts.User do
      allow_nil?(false)
    end
  end

  identities do
    identity(:unique_kind_per_user, [:user_id, :kind, :name])
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)
      accept([:kind, :name, :value, :metadata])

      argument :user_id, :uuid do
        allow_nil?(false)
      end

      change(manage_relationship(:user_id, :user, type: :append))
    end

    update :update do
      primary?(true)
      accept([:name, :value, :metadata])
      require_atomic?(false)
    end

    update :rotate do
      accept([:value])
      require_atomic?(false)

      change(fn changeset, _ ->
        Ash.Changeset.change_attribute(
          changeset,
          :metadata,
          Map.put(
            Ash.Changeset.get_attribute(changeset, :metadata) || %{},
            "rotated_at",
            DateTime.to_iso8601(DateTime.utc_now())
          )
        )
      end)
    end
  end
end
