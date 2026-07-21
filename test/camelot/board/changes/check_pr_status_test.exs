defmodule Camelot.Board.Changes.CheckPrStatusTest do
  use ExUnit.Case, async: true

  alias Camelot.Board.Changes.CheckPrStatus

  @commit "2026-07-09T13:42:09Z"

  defp comment(created, login \\ "T0ha") do
    %{"created_at" => created, "user" => %{"login" => login}}
  end

  describe "new_comments?/3" do
    test "a comment newer than the last commit and unseen triggers" do
      comments = [comment("2026-07-10T05:19:45Z")]

      assert CheckPrStatus.new_comments?(comments, @commit, nil)
    end

    test "reviewer sharing the PR author account still counts (no author filter)" do
      # Regression: runner opens the PR with the user's token, so the
      # reviewer's login equals the PR author's — must NOT be dropped.
      comments = [comment("2026-07-10T05:19:45Z", "T0ha")]

      assert CheckPrStatus.new_comments?(comments, @commit, nil)
    end

    test "a comment older than the last commit does not trigger" do
      comments = [comment("2026-07-09T10:00:00Z")]

      refute CheckPrStatus.new_comments?(comments, @commit, nil)
    end

    test "an already-seen comment does not trigger" do
      created = "2026-07-10T05:19:45Z"
      {:ok, seen_at, _} = DateTime.from_iso8601(created)

      refute CheckPrStatus.new_comments?([comment(created)], @commit, seen_at)
    end

    test "a comment after the seen marker triggers again" do
      {:ok, seen_at, _} = DateTime.from_iso8601("2026-07-10T05:19:45Z")
      comments = [comment("2026-07-10T06:00:00Z")]

      assert CheckPrStatus.new_comments?(comments, @commit, seen_at)
    end

    test "no commits treats any unseen comment as new" do
      assert CheckPrStatus.new_comments?([comment("2026-07-10T05:19:45Z")], nil, nil)
    end

    test "no comments is never new" do
      refute CheckPrStatus.new_comments?([], @commit, nil)
    end
  end

  describe "merge_conflict?/1" do
    test "mergeable false and state dirty is a conflict" do
      pr = %{"mergeable" => false, "mergeable_state" => "dirty"}

      assert CheckPrStatus.merge_conflict?(pr)
    end

    test "mergeable nil (still computing) is not a conflict" do
      pr = %{"mergeable" => nil, "mergeable_state" => "unknown"}

      refute CheckPrStatus.merge_conflict?(pr)
    end

    test "mergeable true is not a conflict" do
      pr = %{"mergeable" => true, "mergeable_state" => "clean"}

      refute CheckPrStatus.merge_conflict?(pr)
    end

    test "mergeable false but state blocked (branch protection) is not a conflict" do
      pr = %{"mergeable" => false, "mergeable_state" => "blocked"}

      refute CheckPrStatus.merge_conflict?(pr)
    end

    test "mergeable false but state behind is not a conflict" do
      pr = %{"mergeable" => false, "mergeable_state" => "behind"}

      refute CheckPrStatus.merge_conflict?(pr)
    end

    test "empty map is not a conflict" do
      refute CheckPrStatus.merge_conflict?(%{})
    end

    test "mergeable false with nil state is not a conflict" do
      pr = %{"mergeable" => false, "mergeable_state" => nil}

      refute CheckPrStatus.merge_conflict?(pr)
    end
  end

  describe "ci_failing?/1" do
    defp check_run(status, conclusion) do
      %{"status" => status, "conclusion" => conclusion}
    end

    test "no check runs is not failing" do
      refute CheckPrStatus.ci_failing?([])
    end

    test "single completed success is not failing" do
      refute CheckPrStatus.ci_failing?([check_run("completed", "success")])
    end

    test "single completed failure is failing" do
      assert CheckPrStatus.ci_failing?([check_run("completed", "failure")])
    end

    test "in_progress run with nil conclusion is not failing" do
      refute CheckPrStatus.ci_failing?([check_run("in_progress", nil)])
    end

    test "queued run with nil conclusion is not failing" do
      refute CheckPrStatus.ci_failing?([check_run("queued", nil)])
    end

    test "mix of success and failure is failing" do
      runs = [check_run("completed", "success"), check_run("completed", "failure")]

      assert CheckPrStatus.ci_failing?(runs)
    end

    test "completed neutral is not failing" do
      refute CheckPrStatus.ci_failing?([check_run("completed", "neutral")])
    end

    test "completed skipped is not failing" do
      refute CheckPrStatus.ci_failing?([check_run("completed", "skipped")])
    end

    test "completed cancelled is failing" do
      assert CheckPrStatus.ci_failing?([check_run("completed", "cancelled")])
    end

    test "completed timed_out is failing" do
      assert CheckPrStatus.ci_failing?([check_run("completed", "timed_out")])
    end

    test "completed action_required is failing" do
      assert CheckPrStatus.ci_failing?([check_run("completed", "action_required")])
    end

    test "completed stale is not failing" do
      refute CheckPrStatus.ci_failing?([check_run("completed", "stale")])
    end
  end
end
