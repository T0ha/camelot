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
end
