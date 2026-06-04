defmodule Camelot.Projects.Project do
  @moduledoc """
  A project representing a local git repository that
  can be managed by AI agents.
  """
  use Ash.Resource,
    domain: Camelot.Projects,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshOban],
    authorizers: []

  alias Camelot.Projects.Membership

  oban do
    scheduled_actions do
      schedule :sync_github_issues, "*/5 * * * *" do
        action(:sync_github_issues)
        queue(:github)

        worker_module_name(Camelot.Projects.Project.AshOban.ActionWorker.SyncGithubIssues)
      end
    end
  end

  postgres do
    table("projects")
    repo(Camelot.Repo)
  end

  attributes do
    uuid_primary_key(:id)

    attribute :name, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :path, :string do
      allow_nil?(true)
      public?(true)

      description(
        "Filesystem path to the git repository on the Camelot " <>
          "host. Used by LocalPort and DockerEngine (bind-mounted " <>
          "into /workspace). Optional in hosted/Swarm mode — there " <>
          "the runner clones from `github_repo_url` instead."
      )
    end

    attribute :description, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :github_repo_url, :string do
      allow_nil?(true)
      public?(true)

      description(
        "Canonical git remote URL — also used as the clone source " <>
          "for hosted runners when no local `path` is set."
      )
    end

    attribute :github_owner, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :github_repo, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :status, :atom do
      allow_nil?(false)
      public?(true)
      default(:active)
      constraints(one_of: [:active, :archived])
    end

    timestamps()
  end

  relationships do
    many_to_many :users, Camelot.Accounts.User do
      through(Membership)
      source_attribute_on_join_resource(:project_id)
      destination_attribute_on_join_resource(:user_id)
    end

    has_many :memberships, Membership do
      destination_attribute(:project_id)
    end

    has_many :mcps, Camelot.Projects.Mcp do
      destination_attribute(:project_id)
    end
  end

  identities do
    identity(:unique_name, [:name])
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)

      accept([
        :name,
        :path,
        :description,
        :github_repo_url,
        :github_owner,
        :github_repo
      ])
    end

    update :update do
      primary?(true)

      accept([
        :name,
        :path,
        :description,
        :github_repo_url,
        :github_owner,
        :github_repo,
        :status
      ])
    end

    update :archive do
      change(set_attribute(:status, :archived))
    end

    action :sync_github_issues do
      run(Camelot.Projects.Changes.SyncGithubIssues)
    end
  end
end
