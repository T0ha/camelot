defmodule CamelotWeb.TaskLiveApprovePrTest do
  # async: false — installs the GitHub pull request stub in the
  # global application env, and the LiveView process needs the
  # shared sandbox connection.
  use CamelotWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Camelot.Board.Task
  alias Camelot.Projects.Project
  alias Camelot.Support.StubPullRequestApi

  setup :register_and_log_in_user

  setup %{user: user} do
    on_exit(&StubPullRequestApi.uninstall/0)

    {:ok, project} =
      Ash.create(
        Project,
        %{
          name: "approve-pr-#{System.unique_integer([:positive])}",
          path: "/tmp/approve-pr",
          github_owner: "acme-org",
          github_repo: "widgets"
        },
        actor: user
      )

    task =
      Ash.Seed.seed!(Task, %{
        title: "PR task",
        project_id: project.id,
        creator_id: user.id,
        agent_id: agent!("claude_code").id,
        stage: :pr,
        state: :waiting_for_input,
        pr_number: 7,
        pr_url: "https://github.com/acme-org/widgets/pull/7"
      })

    %{task: task, project: project}
  end

  describe "Approve PR" do
    test "merges the PR on GitHub and moves the task to done", %{conn: conn, task: task} do
      StubPullRequestApi.install()
      {:ok, view, html} = live(conn, ~p"/tasks/#{task.id}")
      assert html =~ "Approve PR"

      html =
        view
        |> element(~s(button[phx-value-action="complete"]))
        |> render_click()

      assert_receive {:merge_pull_request, "acme-org", "widgets", 7, _opts}
      assert html =~ "done"
      assert html =~ "PR merged"
      assert Ash.get!(Task, task.id).stage == :done
    end

    test "a refused merge flashes an error and keeps the task in pr", %{conn: conn, task: task} do
      StubPullRequestApi.install(merge: {:error, {:http_error, 405, %{}}})
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      html =
        view
        |> element(~s(button[phx-value-action="complete"]))
        |> render_click()

      assert html =~ "branch protection"

      reloaded = Ash.get!(Task, task.id)
      assert reloaded.stage == :pr
      assert reloaded.state == :waiting_for_input
    end
  end
end
