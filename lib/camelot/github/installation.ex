defmodule Camelot.Github.Installation do
  @moduledoc """
  One row per GitHub App installation on github.com,
  linking it to zero or more Camelot projects.

  Written only by the setup-callback controller
  (`CamelotWeb.GithubSetupController`) and the webhook
  receiver (`CamelotWeb.GithubWebhookController`) via
  system actions — nothing else creates or mutates these
  rows. Like the rest of the `Camelot.Projects` resources
  it links to (`Project`, `Membership`, `Mcp`), access
  control is enforced at the web boundary rather than via
  an `Ash.Policy.Authorizer`.
  """
  use Ash.Resource,
    domain: Camelot.Github,
    data_layer: AshPostgres.DataLayer,
    authorizers: []

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
    has_many :projects, Camelot.Projects.Project do
      destination_attribute(:github_installation_id)
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
  end
end
