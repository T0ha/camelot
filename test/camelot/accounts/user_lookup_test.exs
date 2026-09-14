defmodule Camelot.Accounts.UserLookupTest do
  use Camelot.DataCase, async: true

  alias Camelot.Accounts.User
  alias Camelot.Accounts.UserLookup

  describe "fetch_by_email/1" do
    test "matches case-insensitively on the citext column" do
      user = Ash.Seed.seed!(User, %{email: "Mixed@Example.COM"})

      assert {:ok, found} = UserLookup.fetch_by_email("mixed@example.com")
      assert found.id == user.id
    end

    test "accepts a CiString" do
      user = Ash.Seed.seed!(User, %{email: "ci@example.com"})

      assert {:ok, found} = UserLookup.fetch_by_email(user.email)
      assert found.id == user.id
    end

    test "returns :not_found for an unknown, blank or nil email" do
      assert UserLookup.fetch_by_email("nobody@example.com") == :not_found
      assert UserLookup.fetch_by_email("  ") == :not_found
      assert UserLookup.fetch_by_email(nil) == :not_found
    end
  end

  describe "fetch_by_github_user_id/1" do
    test "finds the user holding that GitHub id" do
      user = Ash.Seed.seed!(User, %{email: "gh@example.com", github_user_id: "99"})

      assert {:ok, found} = UserLookup.fetch_by_github_user_id("99")
      assert found.id == user.id
    end

    test "nil never matches a row with no GitHub id" do
      Ash.Seed.seed!(User, %{email: "nogh@example.com"})

      assert UserLookup.fetch_by_github_user_id(nil) == :not_found
    end

    test "returns :not_found for an unknown id" do
      assert UserLookup.fetch_by_github_user_id("12345") == :not_found
    end
  end
end
