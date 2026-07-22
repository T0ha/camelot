defmodule Camelot.Accounts.User.Changes.SendInvitationEmailTest do
  use Camelot.DataCase, async: false

  import Swoosh.TestAssertions

  alias Ash.Resource.Info
  alias Camelot.Accounts.User
  alias Camelot.Accounts.User.Changes.SendInvitationEmail

  describe ":create_user action" do
    test "sends an invitation email after user creation" do
      admin = Ash.Seed.seed!(User, %{email: "admin@e.com", role: :admin})

      {:ok, user} =
        User
        |> Ash.Changeset.for_create(
          :create_user,
          %{email: "new@e.com", role: :user},
          actor: admin
        )
        |> Ash.create()

      assert_email_sent(to: [{"", to_string(user.email)}])
    end
  end

  describe "resource-level wiring" do
    test "the change is scoped to :create_user, not the resource-wide :create changes" do
      create_user_action = Info.action(User, :create_user)

      assert Enum.any?(create_user_action.changes, fn change ->
               match?(
                 %{change: {SendInvitationEmail, []}},
                 change
               )
             end),
             """
             SendInvitationEmail should be wired into :create_user only, \
             not on: [:create], so self-registering magic-link users \
             don't get this email. Configured changes: \
             #{inspect(create_user_action.changes)}
             """

      resource_changes = Info.changes(User)

      refute Enum.any?(resource_changes, fn change ->
               change.change ==
                 {SendInvitationEmail, []}
             end),
             "SendInvitationEmail should not be a resource-wide change"
    end
  end
end
