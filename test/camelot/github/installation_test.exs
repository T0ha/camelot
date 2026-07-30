defmodule Camelot.Github.InstallationTest do
  use Camelot.DataCase, async: true

  alias Camelot.Github.Installation

  require Ash.Query

  defp unique_installation_id, do: System.unique_integer([:positive])

  defp installation!(attrs \\ %{}) do
    defaults = %{
      installation_id: unique_installation_id(),
      account_login: "acme",
      account_type: :organization
    }

    {:ok, installation} = Ash.create(Installation, Map.merge(defaults, attrs), authorize?: false)
    installation
  end

  describe ":upsert action" do
    test "creates a new row" do
      id = unique_installation_id()

      assert {:ok, installation} =
               Ash.create(
                 Installation,
                 %{
                   installation_id: id,
                   account_login: "acme",
                   account_type: :organization
                 },
                 authorize?: false
               )

      assert installation.installation_id == id
      assert installation.account_login == "acme"
      assert installation.account_type == :organization
      assert is_nil(installation.suspended_at)
      assert is_nil(installation.user_id)
    end

    test "upserts by installation_id, updating login/type in place" do
      id = unique_installation_id()

      {:ok, first} =
        Ash.create(
          Installation,
          %{installation_id: id, account_login: "old-login", account_type: :user},
          authorize?: false
        )

      {:ok, second} =
        Ash.create(
          Installation,
          %{installation_id: id, account_login: "new-login", account_type: :organization},
          authorize?: false
        )

      assert first.id == second.id
      assert second.account_login == "new-login"
      assert second.account_type == :organization
    end
  end

  describe ":suspend / :unsuspend actions" do
    test "suspend stamps suspended_at, unsuspend clears it" do
      installation = installation!()

      {:ok, suspended} = Ash.update(installation, %{}, action: :suspend, authorize?: false)
      assert %DateTime{} = suspended.suspended_at

      {:ok, unsuspended} = Ash.update(suspended, %{}, action: :unsuspend, authorize?: false)
      assert is_nil(unsuspended.suspended_at)
    end
  end

  describe ":link_user action" do
    test "links an unlinked installation to the acting user" do
      installation = installation!()
      user = user!()

      assert {:ok, linked} =
               Ash.update(installation, %{user_id: user.id}, action: :link_user, actor: user)

      assert linked.user_id == user.id
    end

    test "denies linking to a different actor than the target user_id" do
      installation = installation!()
      user = user!()
      other = user!()

      assert {:error, _} =
               Ash.update(installation, %{user_id: user.id}, action: :link_user, actor: other)
    end

    test "denies re-linking an installation already claimed by another user" do
      installation = installation!()
      owner = user!()
      intruder = user!()

      {:ok, linked} =
        Ash.update(installation, %{user_id: owner.id}, action: :link_user, actor: owner)

      assert {:error, _} =
               Ash.update(linked, %{user_id: intruder.id}, action: :link_user, actor: intruder)
    end
  end

  describe "read policy" do
    test "the owning user can read their installation" do
      installation = installation!()
      user = user!()

      {:ok, linked} =
        Ash.update(installation, %{user_id: user.id}, action: :link_user, actor: user)

      assert {:ok, %Installation{}} = Ash.get(Installation, linked.id, actor: user)
    end

    test "another user cannot read someone else's installation" do
      installation = installation!()
      owner = user!()
      other = user!()

      {:ok, linked} =
        Ash.update(installation, %{user_id: owner.id}, action: :link_user, actor: owner)

      assert {:error, _} = Ash.get(Installation, linked.id, actor: other)
    end
  end

  describe "destroy policy" do
    test "the owning user can destroy their installation" do
      installation = installation!()
      user = user!()

      {:ok, linked} =
        Ash.update(installation, %{user_id: user.id}, action: :link_user, actor: user)

      assert :ok = Ash.destroy(linked, actor: user)
    end

    test "another user cannot destroy someone else's installation" do
      installation = installation!()
      owner = user!()
      other = user!()

      {:ok, linked} =
        Ash.update(installation, %{user_id: owner.id}, action: :link_user, actor: owner)

      assert {:error, _} = Ash.destroy(linked, actor: other)
    end
  end
end
