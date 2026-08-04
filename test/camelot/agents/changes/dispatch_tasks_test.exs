defmodule Camelot.Agents.Changes.DispatchTasksTest do
  use ExUnit.Case, async: true

  alias Camelot.Accounts.User
  alias Camelot.Agents.Changes.DispatchTasks
  alias Camelot.Board.Task
  alias Camelot.Github.Installation
  alias Camelot.Projects.Project

  describe "installation_id/1" do
    test "resolves the task creator's connected installation id" do
      task = %Task{creator: %User{github_installations: [%Installation{installation_id: 7, account_login: "acme-org"}]}}
      assert DispatchTasks.installation_id(task) == 7
    end

    test "is nil when the creator has no connected installation" do
      task = %Task{creator: %User{github_installations: []}}
      assert is_nil(DispatchTasks.installation_id(task))
    end

    test "resolves the installation matching the task's project github_owner when the creator has several" do
      task = %Task{
        project: %Project{github_owner: "other-org"},
        creator: %User{
          github_installations: [
            %Installation{installation_id: 1, account_login: "acme-org"},
            %Installation{installation_id: 2, account_login: "other-org"}
          ]
        }
      }

      assert DispatchTasks.installation_id(task) == 2
    end
  end
end
