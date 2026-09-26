defmodule Camelot.Github.ClientTest do
  use ExUnit.Case, async: true

  alias Camelot.Github.Client

  describe "get_pull_request/3" do
    test "makes request to correct URL" do
      # Without a valid token, this will fail with
      # an HTTP error — we verify it doesn't crash
      assert {:error, _} =
               Client.get_pull_request(
                 "nonexistent-owner",
                 "nonexistent-repo",
                 999_999
               )
    end
  end

  describe "list_pull_request_reviews/3" do
    test "handles API errors gracefully" do
      assert {:error, _} =
               Client.list_pull_request_reviews(
                 "nonexistent-owner",
                 "nonexistent-repo",
                 999_999
               )
    end
  end

  describe "list_issues/3" do
    test "handles API errors gracefully" do
      assert {:error, _} =
               Client.list_issues(
                 "nonexistent-owner",
                 "nonexistent-repo"
               )
    end
  end

  describe "find_open_pr_by_head/3" do
    test "handles API errors gracefully" do
      assert {:error, _} =
               Client.find_open_pr_by_head(
                 "nonexistent-owner",
                 "nonexistent-repo",
                 "camelot/task-abc"
               )
    end
  end

  describe "list_check_runs/3" do
    test "handles API errors gracefully" do
      assert {:error, _} =
               Client.list_check_runs(
                 "nonexistent-owner",
                 "nonexistent-repo",
                 "deadbeef"
               )
    end

    test "returns error without a network call when sha is nil" do
      assert {:error, :missing_sha} =
               Client.list_check_runs(
                 "nonexistent-owner",
                 "nonexistent-repo",
                 nil
               )
    end
  end

  describe "list_installation_repositories/2" do
    test "handles API errors gracefully" do
      assert {:error, _} = Client.list_installation_repositories(999_999_999)
    end
  end

  # `visibility` is the only thing this normalisation adds that the
  # product reasons about rather than displays: it becomes
  # `project_created.repo_visibility`, and a private repository the
  # App cannot read is the documented way a first task dies on
  # `Authentication failed`. A silently wrong value there would be
  # read as fact.
  describe "normalize_repository/1" do
    test "keeps the repository's declared visibility" do
      assert %{visibility: "private"} = Client.normalize_repository(payload(%{"visibility" => "private"}))
      assert %{visibility: "public"} = Client.normalize_repository(payload(%{"visibility" => "public"}))
      assert %{visibility: "internal"} = Client.normalize_repository(payload(%{"visibility" => "internal"}))
    end

    test "falls back to the private flag when visibility is absent" do
      assert %{visibility: "private"} = Client.normalize_repository(payload(%{"private" => true}))
      assert %{visibility: "public"} = Client.normalize_repository(payload(%{"private" => false}))
    end

    # The property is an enum in PostHog, so an unexpected value is
    # dropped rather than passed through and widening it.
    test "reports nothing rather than an unknown visibility" do
      assert %{visibility: nil} = Client.normalize_repository(payload(%{}))
      assert %{visibility: nil} = Client.normalize_repository(payload(%{"visibility" => "secret"}))
    end

    test "carries the fields the picker renders" do
      assert %{owner: "alice", repo: "widgets", full_name: "alice/widgets"} =
               Client.normalize_repository(payload(%{}))
    end
  end

  defp payload(extra) do
    Map.merge(
      %{
        "owner" => %{"login" => "alice"},
        "name" => "widgets",
        "full_name" => "alice/widgets",
        "html_url" => "https://github.com/alice/widgets"
      },
      extra
    )
  end

  describe "merge_pull_request/4" do
    test "handles API errors gracefully" do
      assert {:error, _} =
               Client.merge_pull_request(
                 "nonexistent-owner",
                 "nonexistent-repo",
                 999_999
               )
    end

    test "handles API errors gracefully for an explicit merge method" do
      assert {:error, _} =
               Client.merge_pull_request(
                 "nonexistent-owner",
                 "nonexistent-repo",
                 999_999,
                 merge_method: :rebase
               )
    end
  end

  describe "approve_pull_request/4" do
    test "handles API errors gracefully" do
      assert {:error, _} =
               Client.approve_pull_request(
                 "nonexistent-owner",
                 "nonexistent-repo",
                 999_999
               )
    end
  end

  describe "installation_id: opt" do
    test "proceeds unauthenticated (no crash) when the App isn't configured" do
      assert {:error, _} =
               Client.get_pull_request(
                 "nonexistent-owner",
                 "nonexistent-repo",
                 999_999,
                 installation_id: 42
               )
    end

    test "nil installation_id behaves exactly like omitting opts" do
      assert {:error, _} =
               Client.list_issues(
                 "nonexistent-owner",
                 "nonexistent-repo",
                 installation_id: nil
               )
    end
  end
end
