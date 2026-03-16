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
      allow_nil?(false)
      public?(true)
      description("Filesystem path to the git repository")
    end

    attribute :description, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :github_repo_url, :string do
      allow_nil?(true)
      public?(true)
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

  identities do
    identity(:unique_name, [:name])
    identity(:unique_path, [:path])
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
