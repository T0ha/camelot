defmodule Camelot.Board.Changes.CheckPrStatusTest do
  use ExUnit.Case, async: true

  alias Camelot.Accounts.User
  alias Camelot.Board.Changes.CheckPrStatus
  alias Camelot.Board.Task
  alias Camelot.Github.Installation
  alias Camelot.Projects.Project

  @commit "2026-07-09T13:42:09Z"

  defp comment(created, login \\ "T0ha") do
    %{"created_at" => created, "user" => %{"login" => login}}
  end

  defp review(state, submitted_at, login \\ "T0ha") do
    %{
      "state" => state,
      "submitted_at" => submitted_at,
      "user" => %{"login" => login}
    }
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

  describe "latest_reviews/1" do
    test "keeps only each reviewer's most recent verdict" do
      reviews = [
        review("CHANGES_REQUESTED", "2026-07-09T10:00:00Z"),
        review("APPROVED", "2026-07-10T05:19:45Z")
      ]

      assert [%{"state" => "APPROVED"}] = CheckPrStatus.latest_reviews(reviews)
    end

    test "keeps one verdict per reviewer" do
      reviews = [
        review("APPROVED", "2026-07-10T05:19:45Z", "T0ha"),
        review("CHANGES_REQUESTED", "2026-07-10T06:00:00Z", "someone")
      ]

      states =
        reviews
        |> CheckPrStatus.latest_reviews()
        |> Enum.map(& &1["state"])
        |> Enum.sort()

      assert states == ["APPROVED", "CHANGES_REQUESTED"]
    end

    test "stateless COMMENTED reviews never supersede a verdict" do
      reviews = [
        review("CHANGES_REQUESTED", "2026-07-10T05:19:45Z"),
        review("COMMENTED", "2026-07-10T06:00:00Z")
      ]

      assert [%{"state" => "CHANGES_REQUESTED"}] =
               CheckPrStatus.latest_reviews(reviews)
    end
  end

  describe "changes_requested?/3" do
    test "an unaddressed verdict newer than the last commit triggers" do
      reviews = [review("CHANGES_REQUESTED", "2026-07-10T05:19:45Z")]

      assert CheckPrStatus.changes_requested?(reviews, @commit, nil)
    end

    test "a verdict older than the last commit does not trigger" do
      # Regression: one undismissed review re-dispatched the agent every
      # two minutes for eight hours. Pushing a fix addresses the review.
      reviews = [review("CHANGES_REQUESTED", "2026-07-09T10:00:00Z")]

      refute CheckPrStatus.changes_requested?(reviews, @commit, nil)
    end

    test "an already-seen verdict does not trigger" do
      submitted = "2026-07-10T05:19:45Z"
      {:ok, seen_at, _} = DateTime.from_iso8601(submitted)
      reviews = [review("CHANGES_REQUESTED", submitted)]

      refute CheckPrStatus.changes_requested?(reviews, @commit, seen_at)
    end

    test "a verdict superseded by an approval does not trigger" do
      reviews = [
        review("CHANGES_REQUESTED", "2026-07-10T05:19:45Z"),
        review("APPROVED", "2026-07-10T06:00:00Z")
      ]

      refute CheckPrStatus.changes_requested?(reviews, @commit, nil)
    end

    test "a dismissed verdict does not trigger" do
      reviews = [
        review("CHANGES_REQUESTED", "2026-07-10T05:19:45Z"),
        review("DISMISSED", "2026-07-10T06:00:00Z")
      ]

      refute CheckPrStatus.changes_requested?(reviews, @commit, nil)
    end

    test "no reviews never triggers" do
      refute CheckPrStatus.changes_requested?([], @commit, nil)
    end
  end

  describe "approved?/1" do
    test "a current approval completes the task" do
      assert CheckPrStatus.approved?([review("APPROVED", "2026-07-10T05:19:45Z")])
    end

    test "an approval following requested changes still counts" do
      reviews = [
        review("CHANGES_REQUESTED", "2026-07-10T05:19:45Z"),
        review("APPROVED", "2026-07-10T06:00:00Z")
      ]

      assert CheckPrStatus.approved?(reviews)
    end

    test "an approval superseded by requested changes does not count" do
      reviews = [
        review("APPROVED", "2026-07-10T05:19:45Z"),
        review("CHANGES_REQUESTED", "2026-07-10T06:00:00Z")
      ]

      refute CheckPrStatus.approved?(reviews)
    end
  end

  describe "feedback_seen_at/2" do
    test "spans both comments and review verdicts" do
      comments = [comment("2026-07-10T05:19:45Z")]
      reviews = [review("CHANGES_REQUESTED", "2026-07-10T06:00:00Z")]

      seen_at = CheckPrStatus.feedback_seen_at(comments, reviews)

      # A body-less review leaves no comment; marking only the latest
      # comment would leave the review unseen and re-dispatch forever.
      refute CheckPrStatus.changes_requested?(reviews, @commit, seen_at)
    end

    test "takes the newest marker across both surfaces" do
      comments = [comment("2026-07-10T07:00:00Z")]
      reviews = [review("CHANGES_REQUESTED", "2026-07-10T06:00:00Z")]

      assert CheckPrStatus.feedback_seen_at(comments, reviews) ==
               ~U[2026-07-10 07:00:00Z]
    end

    test "no feedback at all falls back to now" do
      before = DateTime.utc_now()

      assert DateTime.compare(CheckPrStatus.feedback_seen_at([], []), before) in [
               :gt,
               :eq
             ]
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

  describe "merge_review_feedback/3" do
    test "folds inline review comments into the comment set" do
      review_comment = %{
        "created_at" => "2026-07-10T05:19:45Z",
        "user" => %{"login" => "T0ha"},
        "body" => "is_list is not needed here.",
        "path" => "lib/foo.ex",
        "line" => 12
      }

      assert [%{"body" => "is_list is not needed here."}] =
               CheckPrStatus.merge_review_feedback([], [review_comment], [])
    end

    test "folds a COMMENTED review body into the comment set" do
      review = %{
        "state" => "COMMENTED",
        "submitted_at" => "2026-07-10T05:19:45Z",
        "user" => %{"login" => "T0ha"},
        "body" => "Please tidy this up."
      }

      assert [%{"created_at" => "2026-07-10T05:19:45Z", "body" => "Please tidy this up."}] =
               CheckPrStatus.merge_review_feedback([], [], [review])
    end

    test "drops empty-body reviews (inline-only reviews carry no body)" do
      review = %{
        "state" => "COMMENTED",
        "submitted_at" => "2026-07-10T05:19:45Z",
        "user" => %{"login" => "T0ha"},
        "body" => ""
      }

      assert CheckPrStatus.merge_review_feedback([], [], [review]) == []
    end

    test "keeps existing issue comments alongside review feedback" do
      issue = comment("2026-07-10T05:00:00Z")
      review_comment = %{"created_at" => "2026-07-10T05:19:45Z", "user" => %{}, "body" => "x"}

      merged = CheckPrStatus.merge_review_feedback([issue], [review_comment], [])

      assert length(merged) == 2
    end

    test "an inline review comment newer than the last commit triggers detection" do
      review_comment = %{"created_at" => "2026-07-10T05:19:45Z", "user" => %{}, "body" => "x"}
      merged = CheckPrStatus.merge_review_feedback([], [review_comment], [])

      assert CheckPrStatus.new_comments?(merged, @commit, nil)
    end
  end

  describe "auto_fix_available?/1" do
    test "allows fixes below the default cap of 2" do
      assert CheckPrStatus.auto_fix_available?(%Task{pr_auto_fix_attempts: 0})
      assert CheckPrStatus.auto_fix_available?(%Task{pr_auto_fix_attempts: 1})
    end

    test "stops once the default cap of 2 is reached" do
      refute CheckPrStatus.auto_fix_available?(%Task{pr_auto_fix_attempts: 2})
      refute CheckPrStatus.auto_fix_available?(%Task{pr_auto_fix_attempts: 3})
    end
  end

  describe "under_cap?/2" do
    test "an integer cap stops at the configured number of attempts" do
      assert CheckPrStatus.under_cap?(0, 3)
      assert CheckPrStatus.under_cap?(2, 3)
      refute CheckPrStatus.under_cap?(3, 3)
      refute CheckPrStatus.under_cap?(4, 3)
    end

    test ":infinity never gives up, no matter how many attempts" do
      assert CheckPrStatus.under_cap?(0, :infinity)
      assert CheckPrStatus.under_cap?(99, :infinity)
    end
  end

  describe "max_auto_fix_attempts/0" do
    test "defaults to 2 when unconfigured" do
      assert CheckPrStatus.max_auto_fix_attempts() == 2
    end
  end

  describe "best_effort_check_runs/1" do
    test "passes a successful fetch through unchanged" do
      runs = [%{"status" => "completed", "conclusion" => "success"}]

      assert CheckPrStatus.best_effort_check_runs({:ok, runs}) == {:ok, runs}
    end

    test "degrades an error to no checks so the poll never aborts" do
      # Regression: a missing Checks permission 403s the check-runs
      # endpoint; that must not take down the whole PR reconciliation.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert CheckPrStatus.best_effort_check_runs({:error, {:http_error, 403, %{"message" => "no"}}}) == {:ok, []}
        end)

      assert log =~ "check-runs unavailable"
    end
  end

  describe "installation_id/1" do
    test "resolves the task creator's connected installation id" do
      task = %Task{creator: %User{github_installations: [%Installation{installation_id: 42, account_login: "acme-org"}]}}
      assert CheckPrStatus.installation_id(task) == 42
    end

    test "is nil when the creator has no connected installation" do
      task = %Task{creator: %User{github_installations: []}}
      assert is_nil(CheckPrStatus.installation_id(task))
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

      assert CheckPrStatus.installation_id(task) == 2
    end
  end
end
