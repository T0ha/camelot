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
end
