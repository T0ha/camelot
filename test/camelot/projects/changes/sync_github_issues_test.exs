defmodule Camelot.Projects.Changes.SyncGithubIssuesTest do
  use ExUnit.Case, async: true

  alias Camelot.Accounts.User
  alias Camelot.Github.Installation
  alias Camelot.Projects.Changes.SyncGithubIssues
  alias Camelot.Projects.Membership
  alias Camelot.Projects.Project

  describe "installation_id/1" do
    test "resolves the project owner's connected installation id" do
      project = %Project{
        github_owner: "acme-org",
        owner_membership: %Membership{
          user: %User{github_installations: [%Installation{installation_id: 99, account_login: "acme-org"}]}
        }
      }

      assert SyncGithubIssues.installation_id(project) == 99
    end

    test "is nil when the project has no owner membership" do
      assert is_nil(SyncGithubIssues.installation_id(%Project{owner_membership: nil}))
    end

    test "is nil when the owner has no connected installation" do
      project = %Project{
        owner_membership: %Membership{user: %User{github_installations: []}}
      }

      assert is_nil(SyncGithubIssues.installation_id(project))
    end

    test "resolves the installation matching the project's github_owner when the user has several" do
      project = %Project{
        github_owner: "other-org",
        owner_membership: %Membership{
          user: %User{
            github_installations: [
              %Installation{installation_id: 1, account_login: "acme-org"},
              %Installation{installation_id: 2, account_login: "other-org"}
            ]
          }
        }
      }

      assert SyncGithubIssues.installation_id(project) == 2
    end
  end

  describe "syncable?/1" do
    defp syncable_project(attrs \\ %{}) do
      defaults = %{
        status: :active,
        github_owner: "acme-org",
        github_repo: "widgets",
        owner_membership: %Membership{user: %User{}}
      }

      struct!(Project, Map.merge(defaults, attrs))
    end

    test "an active project with a repo and an owner syncs" do
      assert SyncGithubIssues.syncable?(syncable_project())
    end

    test "an archived project does not sync" do
      # Archiving a project used to stop nothing: issues kept being
      # imported into a board nobody looks at any more.
      refute SyncGithubIssues.syncable?(syncable_project(%{status: :archived}))
    end

    test "a project without a github owner does not sync" do
      refute SyncGithubIssues.syncable?(syncable_project(%{github_owner: nil}))
    end

    test "a project without a github repo does not sync" do
      refute SyncGithubIssues.syncable?(syncable_project(%{github_repo: nil}))
    end

    test "a project without an owner membership does not sync" do
      refute SyncGithubIssues.syncable?(syncable_project(%{owner_membership: nil}))
    end
  end
end
