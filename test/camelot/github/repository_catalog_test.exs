defmodule Camelot.Github.RepositoryCatalogTest do
  use Camelot.DataCase, async: true

  alias Camelot.Github.Installation
  alias Camelot.Github.RepositoryCatalog
  alias Camelot.Telemetry.Reason

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

  # An empty repository picker was the quietest failure in the
  # product: the user sees nothing to pick and we saw nothing at all,
  # while PostHog's dead clicks piled up on the field it feeds. Both
  # ways of arriving there now carry a bounded reason.
  describe "list_for_user/1 telemetry" do
    test "a user with no installation is reported rather than just left empty" do
      user = user!()

      RepositoryCatalog.list_for_user(user)

      assert %{distinct_id: distinct_id, properties: properties} = captured_resolve_failure()
      assert distinct_id == user.id
      assert properties.reason == :no_installation
    end

    test "an installation whose listing fails is reported with a bounded reason" do
      user = user!()
      link!(installation!(), user)

      RepositoryCatalog.list_for_user(user)

      assert %{properties: properties} = captured_resolve_failure()
      assert properties.reason in Reason.reasons()
      refute properties.reason == :no_installation
    end

    test "a suspended installation is counted as having none" do
      user = user!()

      %{account_login: "acme"}
      |> installation!()
      |> link!(user)
      |> Ash.update!(%{}, action: :suspend, authorize?: false)

      RepositoryCatalog.list_for_user(user)

      assert %{properties: %{reason: :no_installation}} = captured_resolve_failure()
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

  defp captured_resolve_failure do
    Enum.find(PostHog.Test.all_captured(), &(&1.event == "project_repo_resolve_failed"))
  end
end
