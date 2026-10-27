defmodule Camelot.Board.IssueCommentsTest do
  use Camelot.DataCase, async: true

  alias Camelot.Board.IssueComments
  alias Camelot.Board.Task
  alias Camelot.Projects.Membership
  alias Camelot.Projects.Project

  @owner_gh 1001
  @member_gh 1002
  @stranger_gh 1003
  @plan_comment_id 500

  setup do
    owner = user!(%{github_user_id: "#{@owner_gh}"})
    member = user!(%{github_user_id: "#{@member_gh}"})

    project =
      Ash.create!(
        Project,
        %{name: "issue-comments-#{System.unique_integer([:positive])}", path: "/tmp/ic"},
        actor: owner
      )

    Ash.Seed.seed!(Membership, %{project_id: project.id, user_id: member.id, role: :member})

    task =
      Ash.Seed.seed!(Task, %{
        title: "GH#3: Gadgets",
        project_id: project.id,
        creator_id: owner.id,
        agent_id: agent!("claude_code").id,
        stage: :pr,
        state: :waiting_for_input,
        issue_number: 3,
        pr_number: 4,
        plan_comment_id: @plan_comment_id,
        inserted_at: ~U[2026-09-30 00:00:00.000000Z]
      })

    %{task: task}
  end

  defp comment(id, author, attrs \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "body" => "comment #{id}",
        "user" => %{"id" => author, "login" => "user-#{author}"},
        "created_at" => "2026-10-01T10:00:00Z",
        "updated_at" => "2026-10-01T10:00:00Z"
      },
      attrs
    )
  end

  defp thumbs_up(author, created_at \\ "2026-10-01T11:00:00Z") do
    %{"content" => "+1", "user" => %{"id" => author}, "created_at" => created_at}
  end

  describe "window/2" do
    test "keeps comments after the plan comment, sorted by id", %{task: task} do
      comments = [comment(503, @member_gh), comment(501, @member_gh)]

      assert [%{"id" => 501}, %{"id" => 503}] = IssueComments.window(task, comments)
    end

    test "drops Camelot's own bot comments", %{task: task} do
      bot = comment(501, 1, %{"user" => %{"id" => 1, "login" => "camelot-ai-board[bot]"}})

      assert IssueComments.window(task, [bot]) == []
    end

    test "drops comments at or before the plan comment", %{task: task} do
      comments = [comment(@plan_comment_id, @member_gh), comment(@plan_comment_id - 1, @member_gh)]

      assert IssueComments.window(task, comments) == []
    end

    test "drops comments posted before the task was created", %{task: task} do
      old = comment(501, @member_gh, %{"created_at" => "2026-09-29T10:00:00Z"})

      assert IssueComments.window(task, [old]) == []
    end

    test "without a plan comment, keeps every comment since creation", %{task: task} do
      task = %{task | plan_comment_id: nil}

      assert [%{"id" => 7}] = IssueComments.window(task, [comment(7, @member_gh)])
    end
  end

  describe "acted_at/3" do
    test "a member's comment acts at its creation time", %{task: task} do
      assert IssueComments.acted_at(comment(501, @member_gh), [], task.project_id) ==
               "2026-10-01T10:00:00Z"
    end

    test "a stranger's comment without a vouch is ignored", %{task: task} do
      assert IssueComments.acted_at(comment(501, @stranger_gh), [], task.project_id) == nil
    end

    test "a member's 👍 does not vouch for a stranger", %{task: task} do
      reactions = [thumbs_up(@member_gh)]

      assert IssueComments.acted_at(comment(501, @stranger_gh), reactions, task.project_id) == nil
    end

    test "an owner's 👍 vouches, at the time of the 👍", %{task: task} do
      reactions = [thumbs_up(@owner_gh, "2026-10-01T11:30:00Z")]

      assert IssueComments.acted_at(comment(501, @stranger_gh), reactions, task.project_id) ==
               "2026-10-01T11:30:00Z"
    end

    test "an edit after the owner's 👍 voids it", %{task: task} do
      edited = comment(501, @stranger_gh, %{"updated_at" => "2026-10-01T12:00:00Z"})

      assert IssueComments.acted_at(edited, [thumbs_up(@owner_gh)], task.project_id) == nil
    end
  end

  describe "annotate/3" do
    test "stamps acted_at using each comment's reactions", %{task: task} do
      comments = [comment(501, @member_gh), comment(502, @stranger_gh), comment(503, @stranger_gh)]
      reactions = %{502 => [thumbs_up(@owner_gh)]}

      assert [
               %{"id" => 501, "acted_at" => "2026-10-01T10:00:00Z"},
               %{"id" => 502, "acted_at" => "2026-10-01T11:00:00Z"},
               %{"id" => 503, "acted_at" => nil}
             ] = IssueComments.annotate(task, comments, reactions)
    end
  end

  describe "stranger_comment_ids/2" do
    test "lists only comments by non-members", %{task: task} do
      comments = [comment(501, @member_gh), comment(502, @stranger_gh)]

      assert IssueComments.stranger_comment_ids(task, comments) == [502]
    end
  end

  describe "unseen?/2" do
    test "anything is unseen without a marker" do
      assert IssueComments.unseen?("2026-10-01T10:00:00Z", nil)
    end

    test "compares against the marker" do
      assert IssueComments.unseen?("2026-10-01T10:00:01Z", ~U[2026-10-01 10:00:00.000000Z])
      refute IssueComments.unseen?("2026-10-01T10:00:00Z", ~U[2026-10-01 10:00:00.000000Z])
    end

    test "a missing or malformed time is never unseen" do
      refute IssueComments.unseen?(nil, ~U[2026-10-01 10:00:00.000000Z])
      refute IssueComments.unseen?("yesterday", ~U[2026-10-01 10:00:00.000000Z])
    end
  end

  describe "new_since/2" do
    test "keeps accepted comments acted on after the marker" do
      comments = [
        %{"id" => 1, "acted_at" => "2026-10-01T09:00:00Z"},
        %{"id" => 2, "acted_at" => "2026-10-01T11:00:00Z"},
        %{"id" => 3, "acted_at" => nil}
      ]

      assert [%{"id" => 2}] = IssueComments.new_since(comments, ~U[2026-10-01 10:00:00.000000Z])
    end

    test "without a marker keeps every accepted comment" do
      comments = [%{"id" => 1, "acted_at" => "2026-10-01T09:00:00Z"}, %{"id" => 2, "acted_at" => nil}]

      assert [%{"id" => 1}] = IssueComments.new_since(comments, nil)
    end
  end

  describe "seen_marker/1" do
    test "is the latest acted_at" do
      comments = [
        %{"acted_at" => "2026-10-01T11:00:00Z"},
        %{"acted_at" => "2026-10-01T12:00:00Z"},
        %{"acted_at" => "2026-10-01T09:00:00Z"}
      ]

      assert IssueComments.seen_marker(comments) == ~U[2026-10-01 12:00:00Z]
    end
  end

  describe "fetch/1" do
    test "skips GitHub entirely when the task has no issue", %{task: task} do
      assert IssueComments.fetch(%{task | issue_number: nil}) == {:ok, []}
    end

    test "skips GitHub when the issue is the PR itself", %{task: task} do
      assert IssueComments.fetch(%{task | issue_number: 4, pr_number: 4}) == {:ok, []}
    end
  end
end
