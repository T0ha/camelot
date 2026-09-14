defmodule Camelot.Board.PrApprovalTest do
  # async: false — the stub is installed in application env, which is
  # global, and `merge_method/0` reads application env too.
  use Camelot.DataCase, async: false

  alias Camelot.Board.PrApproval
  alias Camelot.Board.Task
  alias Camelot.Projects.Project
  alias Camelot.Support.StubPullRequestApi

  @self_approval_body %{
    "message" => "Unprocessable Entity",
    "errors" => [
      %{"resource" => "PullRequestReview", "message" => "Can not approve your own pull request"}
    ]
  }

  describe "merge_method/0" do
    test "defaults to squash" do
      assert PrApproval.merge_method() == :squash
    end

    test "is overridable via config :camelot, :pr_merge" do
      previous = Application.get_env(:camelot, :pr_merge)
      Application.put_env(:camelot, :pr_merge, method: :rebase)

      on_exit(fn -> restore_env(:pr_merge, previous) end)

      assert PrApproval.merge_method() == :rebase
    end
  end

  describe "merge_outcome/1" do
    test "a 2xx reply means merged" do
      assert PrApproval.merge_outcome({:ok, %{"merged" => true}}) == {:ok, :merged}
    end

    test "405 is not mergeable (branch protection, checks, draft)" do
      assert PrApproval.merge_outcome(http_error(405)) == {:error, :not_mergeable}
    end

    test "409 is a merge conflict" do
      assert PrApproval.merge_outcome(http_error(409)) == {:error, :conflict}
    end

    test "403 means the App lacks write access" do
      assert PrApproval.merge_outcome(http_error(403)) == {:error, :forbidden}
    end

    test "404 means the PR or repo is not visible to the App" do
      assert PrApproval.merge_outcome(http_error(404)) == {:error, :not_found}
    end

    test "any other status is reported verbatim" do
      assert PrApproval.merge_outcome(http_error(500)) == {:error, {:github, 500}}
    end

    test "a transport failure is distinguished from an HTTP status" do
      assert PrApproval.merge_outcome({:error, %Req.TransportError{reason: :timeout}}) ==
               {:error, {:transport, %Req.TransportError{reason: :timeout}}}
    end
  end

  describe "error_message/1" do
    test "every merge failure reason gets actionable copy" do
      reasons = [
        :not_mergeable,
        :conflict,
        :forbidden,
        :not_found,
        {:github, 500},
        {:transport, :timeout},
        {:transition, :whatever}
      ]

      for reason <- reasons do
        message = PrApproval.error_message(reason)
        assert is_binary(message)
        assert String.length(message) > 20
      end
    end

    test "the 405 message names the likely causes" do
      assert PrApproval.error_message(:not_mergeable) =~ "branch protection"
    end
  end

  describe "self_approval_error?/1" do
    test "true for GitHub's 422 self-approval refusal" do
      assert PrApproval.self_approval_error?({:http_error, 422, @self_approval_body})
    end

    test "false for any other 422" do
      body = %{"message" => "Validation Failed", "errors" => []}
      refute PrApproval.self_approval_error?({:http_error, 422, body})
    end

    test "false for non-HTTP failures" do
      refute PrApproval.self_approval_error?(:timeout)
    end
  end

  describe "approve_and_merge/1" do
    setup do
      on_exit(&StubPullRequestApi.uninstall/0)
      user = user!()

      {:ok, project} =
        Ash.create(
          Project,
          %{
            name: "pr-approval-#{System.unique_integer([:positive])}",
            path: "/tmp/pr-approval",
            github_owner: "acme-org",
            github_repo: "widgets"
          },
          actor: user
        )

      %{user: user, project: project}
    end

    test "approves, merges and completes the task", context do
      StubPullRequestApi.install()
      task = pr_task!(context)

      assert {:ok, merged} = PrApproval.approve_and_merge(task)
      assert merged.stage == :done
      assert is_nil(merged.state)

      assert_receive {:approve_pull_request, "acme-org", "widgets", 7, _opts}
      assert_receive {:merge_pull_request, "acme-org", "widgets", 7, opts}
      assert opts[:merge_method] == :squash
    end

    test "merges with the configured merge method", context do
      previous = Application.get_env(:camelot, :pr_merge)
      Application.put_env(:camelot, :pr_merge, method: :merge)
      on_exit(fn -> restore_env(:pr_merge, previous) end)

      StubPullRequestApi.install()

      assert {:ok, _merged} = PrApproval.approve_and_merge(pr_task!(context))

      assert_receive {:merge_pull_request, _owner, _repo, _number, opts}
      assert opts[:merge_method] == :merge
    end

    test "a refused merge leaves the task in the pr stage", context do
      StubPullRequestApi.install(merge: http_error(405))
      task = pr_task!(context)

      assert {:error, :not_mergeable} = PrApproval.approve_and_merge(task)

      reloaded = Ash.get!(Task, task.id)
      assert reloaded.stage == :pr
      assert reloaded.state == :waiting_for_input
    end

    test "GitHub refusing self-approval still merges", context do
      StubPullRequestApi.install(approve: http_error(422, @self_approval_body))

      assert {:ok, merged} = PrApproval.approve_and_merge(pr_task!(context))
      assert merged.stage == :done

      assert_receive {:merge_pull_request, _owner, _repo, _number, _opts}
    end

    test "a task without a PR number completes without calling GitHub", context do
      StubPullRequestApi.install()
      task = pr_task!(context, %{pr_number: nil, pr_url: nil})

      assert {:ok, merged} = PrApproval.approve_and_merge(task)
      assert merged.stage == :done

      refute_receive {:merge_pull_request, _owner, _repo, _number, _opts}
      refute_receive {:approve_pull_request, _owner, _repo, _number, _opts}
    end

    test "a project without a GitHub repo completes without calling GitHub", %{user: user} do
      StubPullRequestApi.install()

      {:ok, local_project} =
        Ash.create(
          Project,
          %{name: "local-#{System.unique_integer([:positive])}", path: "/tmp/local"},
          actor: user
        )

      task = pr_task!(%{user: user, project: local_project})

      assert {:ok, merged} = PrApproval.approve_and_merge(task)
      assert merged.stage == :done

      refute_receive {:merge_pull_request, _owner, _repo, _number, _opts}
    end
  end

  defp pr_task!(%{user: user, project: project}, attrs \\ %{}) do
    Ash.Seed.seed!(
      Task,
      Map.merge(
        %{
          title: "PR task",
          project_id: project.id,
          creator_id: user.id,
          agent_id: agent!("claude_code").id,
          stage: :pr,
          state: :waiting_for_input,
          pr_number: 7,
          pr_url: "https://github.com/acme-org/widgets/pull/7"
        },
        attrs
      )
    )
  end

  defp http_error(status, body \\ %{"message" => "nope"}) do
    {:error, {:http_error, status, body}}
  end

  defp restore_env(key, nil), do: Application.delete_env(:camelot, key)
  defp restore_env(key, previous), do: Application.put_env(:camelot, key, previous)
end
