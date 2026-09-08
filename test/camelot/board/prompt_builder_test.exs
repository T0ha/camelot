defmodule Camelot.Board.PromptBuilderTest do
  use ExUnit.Case, async: true

  alias Camelot.Accounts.User
  alias Camelot.Board.PromptBuilder
  alias Camelot.Board.Task
  alias Camelot.Github.Installation
  alias Camelot.Projects.Project

  describe "comment_location/1" do
    test "inline review comment renders path and line" do
      comment = %{"path" => "lib/foo.ex", "line" => 42}
      assert PromptBuilder.comment_location(comment) == " (lib/foo.ex:42)"
    end

    test "outdated review comment (nil line) renders just the path" do
      comment = %{"path" => "lib/foo.ex", "line" => nil}
      assert PromptBuilder.comment_location(comment) == " (lib/foo.ex)"
    end

    test "top-level issue comment has no locator" do
      assert PromptBuilder.comment_location(%{"body" => "hi"}) == ""
    end

    test "nil path renders no locator" do
      assert PromptBuilder.comment_location(%{"path" => nil, "line" => 3}) == ""
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

      note = PromptBuilder.conflict_note(pr, @task)

      assert note =~ "Merge Conflict"
      assert note =~ "`develop`"
      assert note =~ "camelot/task-#{@task.id}"
      assert note =~ @task.pr_url
    end

    test "a mergeable PR yields no note" do
      pr = %{"mergeable" => true, "mergeable_state" => "clean"}
      assert PromptBuilder.conflict_note(pr, @task) == ""
    end

    test "a PR still being computed by GitHub (mergeable nil) yields no note" do
      pr = %{"mergeable" => nil, "mergeable_state" => "unknown"}
      assert PromptBuilder.conflict_note(pr, @task) == ""
    end

    test "a blocked-but-not-dirty PR yields no note" do
      pr = %{"mergeable" => false, "mergeable_state" => "blocked"}
      assert PromptBuilder.conflict_note(pr, @task) == ""
    end

    test "a dirty PR with no base ref falls back to a generic phrase" do
      pr = %{"mergeable" => false, "mergeable_state" => "dirty"}
      assert PromptBuilder.conflict_note(pr, @task) =~ "the base branch"
    end
  end

  describe "installation_id/1" do
    test "resolves the task creator's connected installation id" do
      task = %Task{creator: %User{github_installations: [%Installation{installation_id: 7, account_login: "acme-org"}]}}
      assert PromptBuilder.installation_id(task) == 7
    end

    test "is nil when the creator has no connected installation" do
      task = %Task{creator: %User{github_installations: []}}
      assert is_nil(PromptBuilder.installation_id(task))
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

      assert PromptBuilder.installation_id(task) == 2
    end
  end

  describe "attachments_block/1" do
    test "lists attachment filenames under .camelot/attachments/" do
      task = %{attachments: [%{filename: "screenshot.png"}, %{filename: "error.log"}]}

      assert PromptBuilder.attachments_block(task) ==
               "Attachments (available under .camelot/attachments/ in the workspace):\n" <>
                 "- screenshot.png\n- error.log"
    end

    test "is blank when the task has no attachments" do
      assert PromptBuilder.attachments_block(%{attachments: []}) == ""
    end

    test "is blank when attachments aren't loaded" do
      assert PromptBuilder.attachments_block(%{}) == ""
    end
  end

  describe "branch_directive/1" do
    @core_api %Project{github_owner: "acme", github_repo: "core-api", name: "core-api"}
    @proto_defs %Project{github_owner: "acme", github_repo: "proto-defs", name: "proto-defs"}

    test "no blockers yields the original single-branch instruction" do
      task = %Task{id: @task.id, project: @core_api, blockers: []}

      directive = PromptBuilder.branch_directive(task)

      assert directive =~ "Work on a git branch named exactly `camelot/task-#{task.id}`"
      assert directive =~ "open the pull request from that branch"
    end

    test "a same-repo blocker at :pr produces the stacked base-branch directive" do
      blocker = %Task{id: "b1111111-0000-0000-0000-000000000001", stage: :pr, project: @core_api}
      task = %Task{id: @task.id, project: @core_api, blockers: [blocker]}

      directive = PromptBuilder.branch_directive(task)

      assert directive =~ "from `camelot/task-#{blocker.id}`"
      assert directive =~ "base branch"
    end

    test "two same-repo blockers at :pr produce the merge wording" do
      blocker_1 = %Task{id: "b1111111-0000-0000-0000-000000000001", stage: :pr, project: @core_api}
      blocker_2 = %Task{id: "b2222222-0000-0000-0000-000000000002", stage: :pr, project: @core_api}
      task = %Task{id: @task.id, project: @core_api, blockers: [blocker_1, blocker_2]}

      directive = PromptBuilder.branch_directive(task)

      assert directive =~ "default branch"
      assert directive =~ "git merge"
      assert directive =~ "camelot/task-#{blocker_1.id}"
      assert directive =~ "camelot/task-#{blocker_2.id}"
    end

    test "a cross-repo blocker at :pr produces no branch directive" do
      blocker = %Task{id: "b1111111-0000-0000-0000-000000000001", stage: :pr, project: @proto_defs}
      task = %Task{id: @task.id, project: @core_api, blockers: [blocker]}

      directive = PromptBuilder.branch_directive(task)

      assert directive =~ "open the pull request from that branch"
      refute directive =~ blocker.id
    end

    test "a same-repo blocker not yet at :pr produces no branch directive" do
      blocker = %Task{id: "b1111111-0000-0000-0000-000000000001", stage: :executing, project: @core_api}
      task = %Task{id: @task.id, project: @core_api, blockers: [blocker]}

      directive = PromptBuilder.branch_directive(task)

      assert directive =~ "open the pull request from that branch"
      refute directive =~ blocker.id
    end
  end

  describe "related_context_block/1" do
    @core_api %Project{github_owner: "acme", github_repo: "core-api", name: "core-api"}
    @proto_defs %Project{github_owner: "acme", github_repo: "proto-defs", name: "proto-defs"}

    @empty_links %{
      blockers: [],
      subtasks: [],
      related_out_tasks: [],
      related_in_tasks: [],
      parent_link: nil
    }

    test "is empty when the task has no links" do
      task = Map.merge(%Task{id: @task.id, project: @core_api}, @empty_links)
      assert PromptBuilder.related_context_block(task) == ""
    end

    test "a same-repo blocker carries title, project, stage, summary, PR and branch note" do
      blocker = %Task{
        id: "b1111111-0000-0000-0000-000000000001",
        title: "Extract the billing client",
        stage: :pr,
        full_plan: "Split the billing client into its own module.",
        pr_url: "https://github.com/acme/core-api/pull/412",
        project: @core_api
      }

      task = Map.merge(%Task{id: @task.id, project: @core_api}, %{@empty_links | blockers: [blocker]})

      block = PromptBuilder.related_context_block(task)

      assert block =~ "--- Related Tasks ---"
      assert block =~ "Depends on: \"Extract the billing client\" [core-api] — stage: pr"
      assert block =~ "Summary: Split the billing client into its own module."
      assert block =~ "PR: https://github.com/acme/core-api/pull/412"
      assert block =~ "Branch: camelot/task-#{blocker.id} (same repo — your base branch)"
    end

    test "a cross-repo blocker's PR line notes the different repo and carries no branch line" do
      blocker = %Task{
        id: "b2222222-0000-0000-0000-000000000002",
        title: "Bump the shared proto",
        stage: :pr,
        pr_url: "https://github.com/acme/proto-defs/pull/77",
        project: @proto_defs
      }

      task = Map.merge(%Task{id: @task.id, project: @core_api}, %{@empty_links | blockers: [blocker]})

      block = PromptBuilder.related_context_block(task)

      assert block =~ "PR: https://github.com/acme/proto-defs/pull/77   (different repo — no branch sharing)"
      refute block =~ "Branch:"
    end

    test "carries the parent task" do
      parent = %Task{id: "aaaaaaaa-0000-0000-0000-000000000001", title: "Split billing out", project: @core_api}
      link = %Camelot.Board.TaskLink{id: "link-1", source_task: parent}

      task = Map.merge(%Task{id: @task.id, project: @core_api}, %{@empty_links | parent_link: link})

      assert PromptBuilder.related_context_block(task) =~ "Parent task: \"Split billing out\" [core-api]"
    end

    test "carries subtasks with their stage" do
      subtask = %Task{
        id: "aaaaaaaa-0000-0000-0000-000000000002",
        title: "Wire the client into checkout",
        stage: :executing,
        project: @proto_defs
      }

      task = Map.merge(%Task{id: @task.id, project: @core_api}, %{@empty_links | subtasks: [subtask]})

      assert PromptBuilder.related_context_block(task) =~
               "Subtask: \"Wire the client into checkout\" [proto-defs] — stage: executing"
    end

    test "carries related tasks in both directions, with a task URL" do
      related_out = %Task{id: "aaaaaaaa-0000-0000-0000-000000000003", title: "Billing dashboard", project: @core_api}
      related_in = %Task{id: "aaaaaaaa-0000-0000-0000-000000000004", title: "Metrics export", project: @core_api}

      task =
        Map.merge(%Task{id: @task.id, project: @core_api}, %{
          @empty_links
          | related_out_tasks: [related_out],
            related_in_tasks: [related_in]
        })

      block = PromptBuilder.related_context_block(task)

      assert block =~ "Related: \"Billing dashboard\" [core-api] — "
      assert block =~ "Related: \"Metrics export\" [core-api] — "
      assert block =~ "/tasks/#{related_out.id}"
      assert block =~ "/tasks/#{related_in.id}"
    end
  end
end
