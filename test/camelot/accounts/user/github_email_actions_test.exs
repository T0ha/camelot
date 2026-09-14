defmodule Camelot.Accounts.User.GithubEmailActionsTest do
  use Camelot.DataCase, async: true

  alias Ash.Error.Forbidden
  alias Camelot.Accounts.User

  defp seed_user!(email, attrs \\ %{}) do
    Ash.Seed.seed!(
      User,
      Map.merge(%{email: email, confirmed_at: DateTime.utc_now()}, attrs)
    )
  end

  describe "adopt_github_email" do
    test "moves the email and clears a previous decline" do
      user = seed_user!("old@example.com", %{github_email_declined: "new@example.com"})

      assert {:ok, updated} =
               Ash.update(user, %{email: "new@example.com"},
                 action: :adopt_github_email,
                 actor: user
               )

      assert to_string(updated.email) == "new@example.com"
      refute updated.github_email_declined
    end

    test "is forbidden for another actor" do
      user = seed_user!("owner@example.com")
      other = seed_user!("other@example.com")

      assert {:error, %Forbidden{}} =
               Ash.update(user, %{email: "taken@example.com"},
                 action: :adopt_github_email,
                 actor: other
               )
    end

    test "errors when the address belongs to another user" do
      user = seed_user!("owner2@example.com")
      seed_user!("occupied@example.com")

      assert {:error, _} =
               Ash.update(user, %{email: "occupied@example.com"},
                 action: :adopt_github_email,
                 actor: user
               )
    end
  end

  describe "decline_github_email" do
    test "records the declined address without touching the email" do
      user = seed_user!("keep@example.com")

      assert {:ok, updated} =
               Ash.update(user, %{email: "new@example.com"},
                 action: :decline_github_email,
                 actor: user
               )

      assert to_string(updated.email) == "keep@example.com"
      assert to_string(updated.github_email_declined) == "new@example.com"
    end

    test "is forbidden for another actor" do
      user = seed_user!("keep2@example.com")
      other = seed_user!("other2@example.com")

      assert {:error, %Forbidden{}} =
               Ash.update(user, %{email: "new@example.com"},
                 action: :decline_github_email,
                 actor: other
               )
    end
  end
end
