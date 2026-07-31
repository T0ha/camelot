defmodule Camelot.Agents.Changes.DispatchTasksTest do
  use ExUnit.Case, async: true

  alias Camelot.Accounts.User
  alias Camelot.Agents.Changes.DispatchTasks
  alias Camelot.Board.Task
  alias Camelot.Github.Installation

  describe "installation_id/1" do
    test "resolves the task creator's connected installation id" do
      task = %Task{creator: %User{github_installation: %Installation{installation_id: 7}}}
      assert DispatchTasks.installation_id(task) == 7
    end

    test "is nil when the creator has no connected installation" do
      task = %Task{creator: %User{github_installation: nil}}
      assert is_nil(DispatchTasks.installation_id(task))
    end
  end
end
