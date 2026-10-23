defmodule Camelot.Board.Changes.PostMergeSummaryTest do
  # async: false — installs the GitHub write stub in the global
  # application env.
  use Camelot.DataCase, async: false

  alias Camelot.Board.Changes.PostMergeSummary
  alias Camelot.Board.Task
  alias Camelot.Projects.Project
  alias Camelot.Support.StubPullRequestApi

  setup do
    StubPullRequestApi.install()
    on_exit(&StubPullRequestApi.uninstall/0)
    user = user!()
    github_installation!(user, %{account_login: "acme-org"})

    project =
      Ash.create!(
        Project,
        %{
          name: "merge-summary-#{System.unique_integer([:positive])}",
          path: "/tmp/merge-summary",
          github_owner: "acme-org",
          github_repo: "widgets"
        },
        actor: user
      )

    task =
      Task
      |> Ash.Seed.seed!(%{
        title: "GH#8: Widgets",
        project_id: project.id,
        creator_id: user.id,
        agent_id: agent!("claude_code").id,
        stage: :pr,
        state: :waiting_for_input,
        plan: "Build widgets",
        pr_number: 21,
        pr_url: "https://github.com/acme-org/widgets/pull/21",
        issue_number: 8
      })
      |> Ash.load!([:project, creator: [:github_installations]], authorize?: false)

    %{task: task}
  end

  defp github(attrs \\ %{}) do
    Map.merge(
      %{
        pr: %{
          "number" => 21,
          "html_url" => "https://github.com/acme-org/widgets/pull/21",
          "title" => "Add widgets",
          "body" => "## Summary\nAdds the widget page.\n\n## Test plan\n- ran it",
          "merged" => true,
          "merged_at" => "2026-10-03T10:00:00Z",
          "merged_by" => %{"login" => "octocat"},
          "additions" => 120,
          "deletions" => 4,
          "changed_files" => 6
        },
        commits: [
          %{"sha" => "abcdef1234567", "commit" => %{"message" => "feat: widgets\n\nbody"}},
          %{"sha" => "1234567abcdef", "commit" => %{"message" => "test: widgets"}}
        ],
        reviews: [%{"state" => "APPROVED", "user" => %{"login" => "reviewer"}}],
        issue: %{
          "state" => "open",
          "labels" => [%{"name" => "camelot"}, %{"name" => "camelot:approved"}]
        },
        comments: []
      },
      attrs
    )
  end

  describe "publish/3 — merged" do
    test "posts one summary, labels and closes the issue", %{task: task} do
      assert :ok = PostMergeSummary.publish(task, :merged, github())

      assert_receive {:create_issue_comment, "acme-org", "widgets", 8, body, _opts}
      assert body =~ "<!-- camelot:merge-summary task=#{task.id} -->"
      assert body =~ "https://github.com/acme-org/widgets/pull/21"
      assert body =~ "+120"
      assert body =~ "-4"
      assert body =~ "6 files"
      assert body =~ "abcdef1"
      assert body =~ "feat: widgets"
      refute body =~ "\n\nbody"
      assert body =~ "Adds the widget page."
      refute body =~ "ran it"
      assert body =~ "octocat"

      assert_receive {:add_issue_labels, "acme-org", "widgets", 8, ["camelot:done"], _opts}
      assert_receive {:remove_issue_label, "acme-org", "widgets", 8, "camelot:approved", _opts}
      refute_receive {:remove_issue_label, _, _, _, "camelot:invalid-config", _}
      assert_receive {:close_issue, "acme-org", "widgets", 8, _opts}

      assert Ash.get!(Task, task.id).merge_summary_posted_at
    end

    test "does not close an issue that is already closed", %{task: task} do
      github = github(%{issue: %{"state" => "closed", "labels" => []}})

      assert :ok = PostMergeSummary.publish(task, :merged, github)
      refute_receive {:close_issue, _, _, _, _}
    end

    test "omits the summary section when the PR body has none", %{task: task} do
      github = github(%{pr: Map.put(github().pr, "body", nil)})

      assert :ok = PostMergeSummary.publish(task, :merged, github)
      assert_receive {:create_issue_comment, _, _, 8, _body, _opts}
    end
  end

  describe "publish/3 — closed without merge" do
    test "posts a short note and leaves the issue open", %{task: task} do
      github = github(%{pr: Map.put(github().pr, "merged", false)})

      assert :ok = PostMergeSummary.publish(task, :closed, github)

      assert_receive {:create_issue_comment, _, _, 8, body, _opts}
      assert body =~ "closed without merge"
      refute_receive {:add_issue_labels, _, _, _, _, _}
      refute_receive {:close_issue, _, _, _, _}
      assert Ash.get!(Task, task.id).merge_summary_posted_at
    end
  end

  describe "publish/3 — idempotency" do
    test "a recorded summary is never posted twice", %{task: task} do
      task = Ash.Seed.update!(task, %{merge_summary_posted_at: DateTime.utc_now()})

      assert :already_posted = PostMergeSummary.publish(task, :merged, github())
      refute_receive {:create_issue_comment, _, _, _, _, _}
    end

    test "a summary comment already on the issue is not duplicated", %{task: task} do
      existing = %{"body" => "<!-- camelot:merge-summary task=#{task.id} -->\nMerged!"}

      assert :already_posted = PostMergeSummary.publish(task, :merged, github(%{comments: [existing]}))

      refute_receive {:create_issue_comment, _, _, _, _, _}
      assert Ash.get!(Task, task.id).merge_summary_posted_at
    end

    test "another task's summary does not count", %{task: task} do
      existing = %{"body" => "<!-- camelot:merge-summary task=other -->"}

      assert :ok = PostMergeSummary.publish(task, :merged, github(%{comments: [existing]}))
      assert_receive {:create_issue_comment, _, _, 8, _, _}
    end

    test "a task without an issue is skipped", %{task: task} do
      task = Ash.Seed.update!(task, %{issue_number: nil})

      assert :skipped = PostMergeSummary.publish(task, :merged, github())
      refute_receive {:create_issue_comment, _, _, _, _, _}
    end

    test "a failed comment leaves the summary unrecorded for a retry", %{task: task} do
      StubPullRequestApi.install(create_issue_comment: {:error, {:http_error, 500, %{}}})

      assert {:error, _} = PostMergeSummary.publish(task, :merged, github())
      assert is_nil(Ash.get!(Task, task.id).merge_summary_posted_at)
    end
  end
end
