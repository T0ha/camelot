defmodule Camelot.Board.Changes.PostPlanToIssueTest do
  # async: false — installs the GitHub write stub in the global
  # application env.
  use Camelot.DataCase, async: false

  alias Camelot.Board.Changes.PostPlanToIssue
  alias Camelot.Board.Task
  alias Camelot.Projects.Project
  alias Camelot.Support.StubPullRequestApi

  setup do
    on_exit(&StubPullRequestApi.uninstall/0)
    user = user!()
    github_installation!(user, %{account_login: "acme-org"})

    project =
      Ash.create!(
        Project,
        %{
          name: "plan-post-#{System.unique_integer([:positive])}",
          path: "/tmp/plan-post",
          github_owner: "acme-org",
          github_repo: "widgets"
        },
        actor: user
      )

    %{project: project, user: user}
  end

  defp seed_task(ctx, attrs) do
    defaults = %{
      title: "GH#5: Widgets",
      project_id: ctx.project.id,
      creator_id: ctx.user.id,
      agent_id: agent!("claude_code").id,
      stage: :planning,
      state: :waiting_for_input,
      plan: "1. Build it\n2. Ship it",
      issue_number: 5
    }

    Task
    |> Ash.Seed.seed!(Map.merge(defaults, attrs))
    |> Ash.load!([:project, creator: [:github_installations]], authorize?: false)
  end

  describe "post_plan/1" do
    test "posts the plan as an issue comment and records its id", ctx do
      StubPullRequestApi.install(create_issue_comment: {:ok, %{"id" => 9001}})
      task = seed_task(ctx, %{})

      assert :ok = PostPlanToIssue.post_plan(task)

      assert_receive {:create_issue_comment, "acme-org", "widgets", 5, body, opts}
      assert body =~ "<!-- camelot:plan task=#{task.id} -->"
      assert body =~ "1. Build it"
      assert body =~ "/approve"
      assert Keyword.has_key?(opts, :installation_id)

      assert Ash.get!(Task, task.id).plan_comment_id == 9001
    end

    test "a re-plan posts a new comment and replaces the stored id", ctx do
      StubPullRequestApi.install(create_issue_comment: {:ok, %{"id" => 9002}})
      task = seed_task(ctx, %{plan_comment_id: 9001})

      assert :ok = PostPlanToIssue.post_plan(task)

      assert_receive {:create_issue_comment, _, _, 5, _body, _opts}
      refute_receive {:update_issue_comment, _, _, _, _, _}
      assert Ash.get!(Task, task.id).plan_comment_id == 9002
    end

    test "prefers the full plan document when there is one", ctx do
      StubPullRequestApi.install()
      task = seed_task(ctx, %{full_plan: "# The complete plan"})

      assert :ok = PostPlanToIssue.post_plan(task)
      assert_receive {:create_issue_comment, _, _, 5, body, _opts}
      assert body =~ "# The complete plan"
    end

    test "skips a task that is not linked to an issue", ctx do
      StubPullRequestApi.install()
      task = seed_task(ctx, %{issue_number: nil})

      assert :skipped = PostPlanToIssue.post_plan(task)
      refute_receive {:create_issue_comment, _, _, _, _, _}
    end

    test "a GitHub failure leaves the plan comment unset", ctx do
      StubPullRequestApi.install(create_issue_comment: {:error, {:http_error, 403, %{}}})
      task = seed_task(ctx, %{})

      assert {:error, _} = PostPlanToIssue.post_plan(task)
      assert is_nil(Ash.get!(Task, task.id).plan_comment_id)
    end
  end

  describe "plan_comment_body/2" do
    test "truncates a very long plan and links to the full one", ctx do
      task = seed_task(ctx, %{plan: String.duplicate("x", 70_000)})
      body = PostPlanToIssue.plan_comment_body(task, "https://camelot.example")

      assert String.length(body) < 62_000
      assert body =~ "https://camelot.example/tasks/#{task.id}/plan"
    end

    test "does not link when the plan fits", ctx do
      task = seed_task(ctx, %{})
      body = PostPlanToIssue.plan_comment_body(task, "https://camelot.example")

      refute body =~ "/tasks/#{task.id}/plan"
    end
  end

  describe "post_ui_approval/1" do
    test "tells the issue the plan was approved in Camelot", ctx do
      StubPullRequestApi.install()
      task = seed_task(ctx, %{stage: :executing, state: :queued})

      assert :ok = PostPlanToIssue.post_ui_approval(task)
      assert_receive {:create_issue_comment, "acme-org", "widgets", 5, body, _opts}
      assert body =~ "Plan approved in Camelot"
    end

    test "skips a task that is not linked to an issue", ctx do
      StubPullRequestApi.install()
      task = seed_task(ctx, %{issue_number: nil})

      assert :skipped = PostPlanToIssue.post_ui_approval(task)
      refute_receive {:create_issue_comment, _, _, _, _, _}
    end
  end
end
