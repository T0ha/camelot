defmodule Camelot.Github.RepositoryCatalogTest do
  use Camelot.DataCase, async: true

  alias Camelot.Github.Installation
  alias Camelot.Github.RepositoryCatalog

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

  defp link!(installation, user) do
    {:ok, linked} =
      Ash.update(installation, %{user_id: user.id}, action: :link_user, actor: user)

    linked
  end

  describe "list_for_user/1" do
    test "returns an empty list for a user with no installations" do
      user = user!()

      assert {:ok, []} = RepositoryCatalog.list_for_user(user)
    end

    test "skips suspended installations without erroring" do
      user = user!()

      %{account_login: "acme"}
      |> installation!()
      |> link!(user)
      |> Ash.update!(%{}, action: :suspend, authorize?: false)

      assert {:ok, []} = RepositoryCatalog.list_for_user(user)
    end

    test "does not blow up when a linked installation's API call errors" do
      user = user!()
      link!(installation!(), user)

      assert {:ok, []} = RepositoryCatalog.list_for_user(user)
    end
  end

  describe "merge_repos/1" do
    test "dedupes by full_name and sorts alphabetically" do
      list_a = [
        %{owner: "acme", repo: "b", full_name: "acme/b", html_url: "https://x/acme/b"},
        %{owner: "acme", repo: "a", full_name: "acme/a", html_url: "https://x/acme/a"}
      ]

      list_b = [
        %{owner: "acme", repo: "a", full_name: "acme/a", html_url: "https://x/acme/a"},
        %{owner: "acme", repo: "c", full_name: "acme/c", html_url: "https://x/acme/c"}
      ]

      merged = RepositoryCatalog.merge_repos([list_a, list_b])

      assert Enum.map(merged, & &1.full_name) == ["acme/a", "acme/b", "acme/c"]
    end

    test "is empty for an empty input" do
      assert RepositoryCatalog.merge_repos([]) == []
    end
  end
end
