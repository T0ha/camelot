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

  describe "attachments_block/1" do
    test "lists attachment filenames under .camelot/attachments/" do
      task = %{attachments: [%{filename: "screenshot.png"}, %{filename: "error.log"}]}

      assert DispatchTasks.attachments_block(task) ==
               "Attachments (available under .camelot/attachments/ in the workspace):\n" <>
                 "- screenshot.png\n- error.log"
    end

    test "is blank when the task has no attachments" do
      assert DispatchTasks.attachments_block(%{attachments: []}) == ""
    end

    test "is blank when attachments aren't loaded" do
      assert DispatchTasks.attachments_block(%{}) == ""
    end
  end
end
