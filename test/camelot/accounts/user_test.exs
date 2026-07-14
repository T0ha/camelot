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

  describe "notification preferences" do
    test "default to enabled" do
      user = Ash.Seed.seed!(User, %{email: "notify-defaults@example.com"})

      assert user.notify_on_waiting_for_input
      assert user.notify_on_error
      assert user.notify_on_done
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

  describe "set_swarm_node_label policy" do
    test "a user can set their own label" do
      user = Ash.Seed.seed!(User, %{email: "self-#{System.unique_integer()}@example.com"})

      assert {:ok, updated} =
               user
               |> Ash.Changeset.for_update(:set_swarm_node_label, %{swarm_node_label: "gpu-1"}, actor: user)
               |> Ash.update()

      assert updated.swarm_node_label == "gpu-1"
    end

    test "an admin can set another user's label" do
      admin = Ash.Seed.seed!(User, %{email: "admin-#{System.unique_integer()}@example.com", role: :admin})
      user = Ash.Seed.seed!(User, %{email: "target-#{System.unique_integer()}@example.com"})

      assert {:ok, updated} =
               user
               |> Ash.Changeset.for_update(:set_swarm_node_label, %{swarm_node_label: "gpu-2"}, actor: admin)
               |> Ash.update()

      assert updated.swarm_node_label == "gpu-2"
    end

    test "a non-admin cannot set another user's label" do
      user = Ash.Seed.seed!(User, %{email: "self-#{System.unique_integer()}@example.com"})
      other = Ash.Seed.seed!(User, %{email: "other-#{System.unique_integer()}@example.com"})

      assert {:error, _} =
               other
               |> Ash.Changeset.for_update(:set_swarm_node_label, %{swarm_node_label: "gpu-3"}, actor: user)
               |> Ash.update()
    end
  end
end
