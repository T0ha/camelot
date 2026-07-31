defmodule Camelot.Github.Installation do
  @moduledoc """
  One row per GitHub App installation on github.com,
  linking it to at most one Camelot user.

  Rows are created and mutated by two independent paths:
  the setup-callback controller
  (`CamelotWeb.GithubSetupController`, which also links
  the row to the connecting user via `:link_user`) and the
  webhook receiver (`CamelotWeb.GithubWebhookController`).
  Both are system/trusted call sites with no acting user in
  scope, so they call in with `authorize?: false`. Reads and
  destroys, on the other hand, are user-driven from the
  profile LiveView, so those go through the policies below.
  """
  use Ash.Resource,
    domain: Camelot.Github,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @account_types [:user, :organization]

  postgres do
    table("github_installations")
    repo(Camelot.Repo)
  end

  attributes do
    uuid_primary_key(:id)

    attribute :installation_id, :integer do
      allow_nil?(false)
      public?(true)
      description("GitHub's numeric installation id")
    end

    attribute :account_login, :string do
      allow_nil?(false)
      public?(true)
      description("Login of the user/org the App is installed on")
    end

    attribute :account_type, :atom do
      allow_nil?(false)
      public?(true)
      constraints(one_of: @account_types)

      description(
        ~s(Normalized from GitHub's "User"/"Organization" ) <>
          "account type"
      )
    end

    attribute :suspended_at, :utc_datetime do
      allow_nil?(true)
      public?(true)
      description("Set when GitHub reports the installation suspended")
    end

    timestamps()
  end

  relationships do
    belongs_to :user, Camelot.Accounts.User do
      allow_nil?(true)
      public?(true)

      description(
        "Camelot user this installation is connected to. Nilable " <>
          "because a row can arrive via the GitHub webhook before " <>
          "the owning user's setup-callback redirect lands and " <>
          "links it via :link_user."
      )
    end
  end

  identities do
    identity(:unique_installation_id, [:installation_id])
  end

  actions do
    defaults([:read, :destroy])

    create :upsert do
      primary?(true)
      accept([:installation_id, :account_login, :account_type])
      upsert?(true)
      upsert_identity(:unique_installation_id)
      upsert_fields([:account_login, :account_type])
    end

    update :suspend do
      change(set_attribute(:suspended_at, &DateTime.utc_now/0))
    end

    update :unsuspend do
      change(set_attribute(:suspended_at, nil))
    end

    update :link_user do
      require_atomic?(false)

      argument :user_id, :uuid do
        allow_nil?(false)
      end

      change(fn changeset, _context ->
        Ash.Changeset.change_attribute(
          changeset,
          :user_id,
          Ash.Changeset.get_argument(changeset, :user_id)
        )
      end)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if(expr(user_id == ^actor(:id)))
    end

    policy action(:destroy) do
      authorize_if(expr(user_id == ^actor(:id)))
    end

    policy action(:link_user) do
      authorize_if(expr(is_nil(user_id) and ^arg(:user_id) == ^actor(:id)))
      authorize_if(expr(user_id == ^actor(:id)))
    end
  end
end
