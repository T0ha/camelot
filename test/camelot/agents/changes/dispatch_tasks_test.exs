defmodule Camelot.Agents.Changes.DispatchTasksTest do
  use ExUnit.Case, async: true

  alias Camelot.Accounts.User
  alias Camelot.Agents.Changes.DispatchTasks
  alias Camelot.Board.Task
  alias Camelot.Github.Installation

  describe "comment_location/1" do
    test "inline review comment renders path and line" do
      comment = %{"path" => "lib/foo.ex", "line" => 42}
      assert DispatchTasks.comment_location(comment) == " (lib/foo.ex:42)"
    end

    test "outdated review comment (nil line) renders just the path" do
      comment = %{"path" => "lib/foo.ex", "line" => nil}
      assert DispatchTasks.comment_location(comment) == " (lib/foo.ex)"
    end

    test "top-level issue comment has no locator" do
      assert DispatchTasks.comment_location(%{"body" => "hi"}) == ""
    end

    test "nil path renders no locator" do
      assert DispatchTasks.comment_location(%{"path" => nil, "line" => 3}) == ""
    end
  end

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
