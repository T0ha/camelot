defmodule Camelot.Board.Changes.DispatchTasksTest do
  use ExUnit.Case, async: true

  alias Camelot.Accounts.User
  alias Camelot.Board.Changes.DispatchTasks
  alias Camelot.Board.Task
  alias Camelot.Github.Installation
  alias Camelot.Projects.Project

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

  describe "conflict_note/2" do
    @task %Task{
      id: "c324c8d8-6e44-42d6-973f-ba8e17f37d2d",
      pr_url: "https://github.com/T0ha/camelot/pull/100"
    }

    test "a dirty PR yields an explicit resolve-and-push instruction" do
      pr = %{
        "mergeable" => false,
        "mergeable_state" => "dirty",
        "base" => %{"ref" => "develop"}
      }

      note = DispatchTasks.conflict_note(pr, @task)

      assert note =~ "Merge Conflict"
      assert note =~ "`develop`"
      assert note =~ "camelot/task-#{@task.id}"
      assert note =~ @task.pr_url
    end

    test "a mergeable PR yields no note" do
      pr = %{"mergeable" => true, "mergeable_state" => "clean"}
      assert DispatchTasks.conflict_note(pr, @task) == ""
    end

    test "a PR still being computed by GitHub (mergeable nil) yields no note" do
      pr = %{"mergeable" => nil, "mergeable_state" => "unknown"}
      assert DispatchTasks.conflict_note(pr, @task) == ""
    end

    test "a blocked-but-not-dirty PR yields no note" do
      pr = %{"mergeable" => false, "mergeable_state" => "blocked"}
      assert DispatchTasks.conflict_note(pr, @task) == ""
    end

    test "a dirty PR with no base ref falls back to a generic phrase" do
      pr = %{"mergeable" => false, "mergeable_state" => "dirty"}
      assert DispatchTasks.conflict_note(pr, @task) =~ "the base branch"
    end
  end

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
