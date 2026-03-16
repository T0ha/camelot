defmodule Camelot.Accounts.UserTest do
  use Camelot.DataCase, async: true

  alias Camelot.Accounts.User

  describe "magic link request" do
    test "requests a magic link for existing user" do
      Ash.Seed.seed!(User, %{email: "test@example.com"})

      strategy =
        AshAuthentication.Info.strategy!(User, :magic_link)

      assert :ok =
               AshAuthentication.Strategy.action(
                 strategy,
                 :request,
                 %{email: "test@example.com"}
               )
    end

    test "requests a magic link for non-existing email" do
      strategy =
        AshAuthentication.Info.strategy!(User, :magic_link)

      assert :ok =
               AshAuthentication.Strategy.action(
                 strategy,
                 :request,
                 %{email: "new@example.com"}
               )
    end
  end

  describe "unique email" do
    test "enforces unique email identity" do
      Ash.Seed.seed!(User, %{email: "dup@example.com"})

      assert_raise Ash.Error.Invalid, fn ->
        Ash.Seed.seed!(User, %{email: "dup@example.com"})
      end
    end
  end
end
