defmodule Camelot.Accounts.User.Senders.SendMagicLinkTest do
  use Camelot.DataCase, async: false

  import Swoosh.TestAssertions

  alias Camelot.Accounts.User
  alias Camelot.Accounts.User.Senders.SendMagicLink

  setup do
    original = Application.fetch_env!(:camelot, :registration_enabled)
    on_exit(fn -> Application.put_env(:camelot, :registration_enabled, original) end)
    :ok
  end

  describe "with registration enabled" do
    setup do
      Application.put_env(:camelot, :registration_enabled, true)
      :ok
    end

    test "sends a magic link to an unknown email (registration path)" do
      :ok = SendMagicLink.send("stranger@example.com", "tok-123", [])
      assert_email_sent(to: [{"", "stranger@example.com"}])
    end

    test "sends a magic link to a known user" do
      user = Ash.Seed.seed!(User, %{email: "invited@example.com"})
      :ok = SendMagicLink.send(user, "tok-123", [])
      assert_email_sent(to: [{"", "invited@example.com"}])
    end
  end

  describe "with registration disabled" do
    setup do
      Application.put_env(:camelot, :registration_enabled, false)
      :ok
    end

    test "drops magic links to unknown emails (registration path)" do
      :ok = SendMagicLink.send("stranger@example.com", "tok-123", [])
      assert_no_email_sent()
    end

    test "still sends magic links to known users" do
      user = Ash.Seed.seed!(User, %{email: "invited@example.com"})
      :ok = SendMagicLink.send(user, "tok-123", [])
      assert_email_sent(to: [{"", "invited@example.com"}])
    end
  end
end
