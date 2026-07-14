defmodule Camelot.Accounts.User.Senders.SendInvitationEmailTest do
  use Camelot.DataCase, async: false

  import Swoosh.TestAssertions

  alias Camelot.Accounts.User
  alias Camelot.Accounts.User.Senders.SendInvitationEmail

  test "delivers an invitation email with a sign-in link carrying UTM tags" do
    user = Ash.Seed.seed!(User, %{email: "invited@example.com"})

    :ok = SendInvitationEmail.deliver(user)

    assert_email_sent(fn email ->
      assert email.to == [{"", "invited@example.com"}]
      assert email.subject =~ "invited"
      assert email.html_body =~ "/sign-in?"
      assert email.html_body =~ "utm_source=email"
      assert email.html_body =~ "utm_medium=invitation"
      assert email.html_body =~ "utm_campaign=admin_invite"
      assert email.text_body =~ "/sign-in?"
    end)
  end
end
