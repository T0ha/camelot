defmodule Camelot.Accounts.User.MagicLinkConfirmationTest do
  use Camelot.DataCase, async: false

  import Swoosh.TestAssertions

  alias Camelot.Accounts.User

  describe "magic-link sign-in for an admin-invited user" do
    test "an invited user can still sign in via magic link after confirm_on_create? is disabled" do
      admin = Ash.Seed.seed!(User, %{email: "admin-ml@e.com", role: :admin})

      {:ok, user} =
        User
        |> Ash.Changeset.for_create(
          :create_user,
          %{email: "invitee-ml@e.com", role: :user},
          actor: admin
        )
        |> Ash.create()

      assert user.confirmed_at

      # Drain the invitation email sent by :create_user before
      # requesting the magic link, so the mailbox assertion below
      # matches the magic-link email, not the invitation one.
      assert_email_sent()

      strategy = AshAuthentication.Info.strategy!(User, :magic_link)

      assert :ok =
               AshAuthentication.Strategy.action(strategy, :request, %{
                 email: to_string(user.email)
               })

      {:email, email} = assert_email_sent()

      [token] =
        Regex.run(~r{/magic_link/([^"\s]+)}, email.html_body, capture: :all_but_first)

      assert {:ok, signed_in_user} =
               AshAuthentication.Strategy.action(strategy, :sign_in, %{"token" => token})

      assert signed_in_user.id == user.id
      assert signed_in_user.confirmed_at
    end
  end
end
