defmodule Camelot.Accounts.User.Senders.SendConfirmationEmailTest do
  use Camelot.DataCase, async: false

  import Swoosh.TestAssertions

  alias Camelot.Accounts.User
  alias Camelot.Accounts.User.Senders.SendConfirmationEmail

  test "delivers a confirmation email with the branded layout" do
    user = Ash.Seed.seed!(User, %{email: "confirm@example.com"})

    :ok = SendConfirmationEmail.send(user, "tok-456", [])

    assert_email_sent(fn email ->
      assert email.to == [{"", "confirm@example.com"}]
      assert email.subject =~ "Confirm"
      assert email.html_body =~ "confirm_new_user?confirm=tok-456"
      assert email.html_body =~ "Camelot AI"
      assert email.html_body =~ "MedievalSharp"
      assert email.html_body =~ "#7c3aed"
      assert email.text_body =~ "confirm_new_user?confirm=tok-456"
    end)
  end
end
