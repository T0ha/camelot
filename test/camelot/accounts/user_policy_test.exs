defmodule Camelot.Accounts.UserPolicyTest do
  use Camelot.DataCase, async: true

  alias Ash.Error.Forbidden
  alias Camelot.Accounts.User

  setup do
    admin = Ash.Seed.seed!(User, %{email: "admin-#{System.unique_integer()}@example.com", role: :admin})
    user = Ash.Seed.seed!(User, %{email: "user-#{System.unique_integer()}@example.com", role: :user})
    other = Ash.Seed.seed!(User, %{email: "other-#{System.unique_integer()}@example.com", role: :user})
    %{admin: admin, user: user, other: other}
  end

  describe "read policy" do
    # Read is intentionally open at the resource layer so managed-relationship
    # lookups (Agent.user, Membership.user, etc.) work without an actor.
    # The "admin sees users, plain users don't" boundary is enforced at the
    # /admin/users LiveView mount (see CamelotWeb.AdminLive.UsersTest).
    test "anyone can read users (admin restriction is UI-layer)", %{user: user} do
      assert {:ok, users} = Ash.read(User, actor: user)
      assert length(users) >= 3
    end
  end

  describe ":create_user policy" do
    test "admin can create users", %{admin: admin} do
      assert {:ok, _} =
               User
               |> Ash.Changeset.for_create(
                 :create_user,
                 %{email: "new-#{System.unique_integer()}@example.com", role: :user},
                 actor: admin
               )
               |> Ash.create()
    end

    test "non-admin cannot create users", %{user: user} do
      assert {:error, %Forbidden{}} =
               User
               |> Ash.Changeset.for_create(
                 :create_user,
                 %{email: "denied-#{System.unique_integer()}@example.com", role: :user},
                 actor: user
               )
               |> Ash.create()
    end
  end

  describe ":set_role policy" do
    test "admin can change another user's role", %{admin: admin, other: other} do
      assert {:ok, updated} =
               other
               |> Ash.Changeset.for_update(:set_role, %{role: :admin}, actor: admin)
               |> Ash.update()

      assert updated.role == :admin
    end

    test "non-admin cannot change roles", %{user: user, other: other} do
      assert {:error, %Forbidden{}} =
               other
               |> Ash.Changeset.for_update(:set_role, %{role: :admin}, actor: user)
               |> Ash.update()
    end
  end
end
