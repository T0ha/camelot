defmodule Camelot.Board.Changes.CheckPrStatusMergeTest do
  # async: false — installs the GitHub pull request stub in the
  # global application env.
  use Camelot.DataCase, async: false

  alias Camelot.Board.Changes.CheckPrStatus
  alias Camelot.Board.Task
  alias Camelot.Projects.Project
  alias Camelot.Support.StubPullRequestApi

  setup do
    on_exit(&StubPullRequestApi.uninstall/0)
    user = user!()

    {:ok, project} =
      Ash.create(
        Project,
        %{
          name: "poll-merge-#{System.unique_integer([:positive])}",
          path: "/tmp/poll-merge",
          github_owner: "acme-org",
          github_repo: "widgets"
        },
        actor: user
      )

    task =
      Ash.Seed.seed!(Task, %{
        title: "Approved PR task",
        project_id: project.id,
        creator_id: user.id,
        agent_id: agent!("claude_code").id,
        stage: :pr,
        state: :waiting_for_input,
        pr_number: 11
      })

    %{task: task}
  end

  describe "merge_approved/1" do
    test "a human approval on GitHub merges the PR and completes", %{task: task} do
      StubPullRequestApi.install()

      assert :ok = CheckPrStatus.merge_approved(task)
      assert_receive {:merge_pull_request, "acme-org", "widgets", 11, _opts}

      assert Ash.get!(Task, task.id).stage == :done
    end

    test "an unmergeable PR leaves the task in the pr stage", %{task: task} do
      StubPullRequestApi.install(merge: {:error, {:http_error, 405, %{}}})

      assert :ok = CheckPrStatus.merge_approved(task)

      reloaded = Ash.get!(Task, task.id)
      assert reloaded.stage == :pr
      assert reloaded.state == :waiting_for_input
    end
  end
end
