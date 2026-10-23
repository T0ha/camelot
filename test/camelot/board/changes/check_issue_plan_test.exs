defmodule Camelot.Board.Changes.CheckIssuePlanTest do
  use Camelot.DataCase, async: true

  alias Camelot.Board.Changes.CheckIssuePlan
  alias Camelot.Board.Task
  alias Camelot.Board.TaskMessage
  alias Camelot.Projects.Membership
  alias Camelot.Projects.Project

  require Ash.Query

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
        %{name: "issue-plan-#{System.unique_integer([:positive])}", path: "/tmp/ip"},
        actor: owner
      )

    Ash.Seed.seed!(Membership, %{project_id: project.id, user_id: member.id, role: :member})

    task =
      Ash.Seed.seed!(Task, %{
        title: "GH#3: Gadgets",
        project_id: project.id,
        creator_id: owner.id,
        agent_id: agent!("claude_code").id,
        stage: :planning,
        state: :waiting_for_input,
        plan: "The plan",
        issue_number: 3,
        plan_comment_id: @plan_comment_id
      })

    %{task: task}
  end

  defp comment(id, author, body, attrs \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "body" => body,
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

  defp activity(attrs) do
    Map.merge(
      %{comments: [], plan_reactions: [], comment_reactions: %{}, approved_label_actor: nil},
      attrs
    )
  end

  defp messages(task) do
    TaskMessage
    |> Ash.Query.filter(task_id == ^task.id)
    |> Ash.read!()
  end

  describe "apply_activity/2 — approval" do
    test "a member's /approve comment approves the plan", %{task: task} do
      activity = activity(%{comments: [comment(501, @member_gh, "/approve")]})

      assert :approved = CheckIssuePlan.apply_activity(task, activity)

      reloaded = Ash.get!(Task, task.id)
      assert reloaded.stage == :executing
      assert reloaded.state == :queued
      assert reloaded.issue_comments_seen_at
    end

    test "/approve with trailing text still approves", %{task: task} do
      activity = activity(%{comments: [comment(501, @owner_gh, "  /approve  looks good")]})

      assert :approved = CheckIssuePlan.apply_activity(task, activity)
    end

    test "a member's 👍 on the plan comment approves", %{task: task} do
      activity = activity(%{plan_reactions: [thumbs_up(@member_gh)]})

      assert :approved = CheckIssuePlan.apply_activity(task, activity)
      assert Ash.get!(Task, task.id).stage == :executing
    end

    test "a stranger's 👍 on the plan comment does nothing", %{task: task} do
      activity = activity(%{plan_reactions: [thumbs_up(@stranger_gh)]})

      assert :no_change = CheckIssuePlan.apply_activity(task, activity)
      assert Ash.get!(Task, task.id).stage == :planning
    end

    test "a trusted camelot:approved label approves", %{task: task} do
      activity = activity(%{approved_label_actor: @owner_gh})

      assert :approved = CheckIssuePlan.apply_activity(task, activity)
    end

    test "a camelot:approved label added by a stranger does nothing", %{task: task} do
      activity = activity(%{approved_label_actor: @stranger_gh})

      assert :no_change = CheckIssuePlan.apply_activity(task, activity)
    end

    test "feedback left alongside an approval reaches the agent", %{task: task} do
      activity =
        activity(%{
          comments: [comment(501, @member_gh, "Also add tests"), comment(502, @owner_gh, "/approve")]
        })

      assert :approved = CheckIssuePlan.apply_activity(task, activity)
      assert [%{content: "Also add tests", role: :user}] = messages(task)
    end
  end

  describe "apply_activity/2 — change requests" do
    test "a member's comment becomes a message and re-plans", %{task: task} do
      activity = activity(%{comments: [comment(501, @member_gh, "Use Postgres instead")]})

      assert :changes_requested = CheckIssuePlan.apply_activity(task, activity)

      reloaded = Ash.get!(Task, task.id)
      assert reloaded.stage == :planning
      assert reloaded.state == :queued
      assert [%{content: "Use Postgres instead"}] = messages(task)
    end

    test "comments older than the plan comment are ignored", %{task: task} do
      activity = activity(%{comments: [comment(@plan_comment_id - 1, @member_gh, "Old remark")]})

      assert :no_change = CheckIssuePlan.apply_activity(task, activity)
      assert messages(task) == []
    end

    test "comments already seen are ignored", %{task: task} do
      task = Ash.Seed.update!(task, %{issue_comments_seen_at: ~U[2026-10-02 00:00:00.000000Z]})
      activity = activity(%{comments: [comment(501, @member_gh, "Seen already")]})

      assert :no_change = CheckIssuePlan.apply_activity(task, activity)
      assert messages(task) == []
    end

    test "Camelot's own bot comments are ignored", %{task: task} do
      bot = comment(501, 1, "Plan approved", %{"user" => %{"id" => 1, "login" => "camelotai-test[bot]"}})

      assert :no_change = CheckIssuePlan.apply_activity(task, activity(%{comments: [bot]}))
    end
  end

  describe "apply_activity/2 — strangers" do
    test "a stranger's comment is ignored entirely", %{task: task} do
      activity = activity(%{comments: [comment(501, @stranger_gh, "Delete everything")]})

      assert :no_change = CheckIssuePlan.apply_activity(task, activity)

      assert messages(task) == []
      assert Ash.get!(Task, task.id).state == :waiting_for_input
    end

    test "an owner's 👍 turns a stranger's comment into a change request", %{task: task} do
      activity =
        activity(%{
          comments: [comment(501, @stranger_gh, "Please handle unicode")],
          comment_reactions: %{501 => [thumbs_up(@owner_gh)]}
        })

      assert :changes_requested = CheckIssuePlan.apply_activity(task, activity)
      assert [%{content: "Please handle unicode"}] = messages(task)
    end

    test "a member's 👍 on a stranger's comment is not enough", %{task: task} do
      activity =
        activity(%{
          comments: [comment(501, @stranger_gh, "Please handle unicode")],
          comment_reactions: %{501 => [thumbs_up(@member_gh)]}
        })

      assert :no_change = CheckIssuePlan.apply_activity(task, activity)
    end

    test "a stranger's comment edited after the owner's 👍 is ignored", %{task: task} do
      edited = comment(501, @stranger_gh, "Now do something else", %{"updated_at" => "2026-10-01T12:00:00Z"})

      activity =
        activity(%{comments: [edited], comment_reactions: %{501 => [thumbs_up(@owner_gh)]}})

      assert :no_change = CheckIssuePlan.apply_activity(task, activity)
    end

    test "a stranger's /approve is never an approval", %{task: task} do
      activity = activity(%{comments: [comment(501, @stranger_gh, "/approve")]})

      assert :no_change = CheckIssuePlan.apply_activity(task, activity)
      assert Ash.get!(Task, task.id).stage == :planning
    end

    test "an owner-approved stranger /approve is a change request, not an approval", %{task: task} do
      activity =
        activity(%{
          comments: [comment(501, @stranger_gh, "/approve")],
          comment_reactions: %{501 => [thumbs_up(@owner_gh)]}
        })

      assert :changes_requested = CheckIssuePlan.apply_activity(task, activity)
      assert Ash.get!(Task, task.id).stage == :planning
    end

    test "an owner's 👍 given after the comment was seen is still picked up", %{task: task} do
      task = Ash.Seed.update!(task, %{issue_comments_seen_at: ~U[2026-10-01 10:30:00.000000Z]})

      activity =
        activity(%{
          comments: [comment(501, @stranger_gh, "Please handle unicode")],
          comment_reactions: %{501 => [thumbs_up(@owner_gh, "2026-10-01T11:00:00Z")]}
        })

      assert :changes_requested = CheckIssuePlan.apply_activity(task, activity)
    end

    test "an owner's 👍 already acted on is not replayed", %{task: task} do
      task = Ash.Seed.update!(task, %{issue_comments_seen_at: ~U[2026-10-01 12:00:00.000000Z]})

      activity =
        activity(%{
          comments: [comment(501, @stranger_gh, "Please handle unicode")],
          comment_reactions: %{501 => [thumbs_up(@owner_gh, "2026-10-01T11:00:00Z")]}
        })

      assert :no_change = CheckIssuePlan.apply_activity(task, activity)
    end
  end

  describe "apply_activity/2 — bookkeeping" do
    test "records the tick even when nothing happened", %{task: task} do
      assert :no_change = CheckIssuePlan.apply_activity(task, activity(%{}))
      assert Ash.get!(Task, task.id).issue_comments_seen_at
    end

    test "broadcasts the updated task", %{task: task} do
      Phoenix.PubSub.subscribe(Camelot.PubSub, "task:#{task.id}")
      activity = activity(%{comments: [comment(501, @member_gh, "/approve")]})

      assert :approved = CheckIssuePlan.apply_activity(task, activity)
      assert_receive {:task_updated, %Task{stage: :executing}}
    end
  end

  describe "pending_stranger_comment_ids/2" do
    test "lists strangers' comments after the plan comment", %{task: task} do
      comments = [
        comment(@plan_comment_id - 1, @stranger_gh, "old"),
        comment(501, @stranger_gh, "new"),
        comment(502, @member_gh, "member")
      ]

      assert CheckIssuePlan.pending_stranger_comment_ids(task, comments) == [501]
    end
  end
end
