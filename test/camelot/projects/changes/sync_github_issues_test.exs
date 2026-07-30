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
        owner_membership: %Membership{
          user: %User{github_installation: %Installation{installation_id: 99}}
        }
      }

      assert SyncGithubIssues.installation_id(project) == 99
    end

    test "is nil when the project has no owner membership" do
      assert is_nil(SyncGithubIssues.installation_id(%Project{owner_membership: nil}))
    end

    test "is nil when the owner has no connected installation" do
      project = %Project{
        owner_membership: %Membership{user: %User{github_installation: nil}}
      }

      assert is_nil(SyncGithubIssues.installation_id(project))
    end
  end
end
