defmodule Camelot.Github.RepositoryCatalogTest do
  # `async: false`: the empty-grant tests stub Req's global default
  # options, the only seam `Camelot.Github.Client` has.
  use Camelot.DataCase, async: false

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

  # The quietest way to reach an empty picker is not a failure at all:
  # every installation answers, none of them with a repository the App
  # was granted. The user is left on `#github_repo_url` — where
  # PostHog's dead clicks pile up — and until now that produced no
  # signal whatsoever, because only installations that *errored* were
  # reported.
  describe "list_for_user/1 with installations that grant nothing" do
    test "reports an installation that lists no repositories" do
      user = user!()
      link!(installation!(), user)
      stub_repositories([])

      assert {:ok, []} = RepositoryCatalog.list_for_user(user)

      assert [%{properties: %{reason: :no_repositories, http_status: nil}}] =
               captured_resolve_failures(user)
    end

    test "reports nothing when the listing returned a repository" do
      user = user!()
      link!(installation!(), user)
      stub_repositories([repository_payload("acme/app")])

      assert {:ok, [%{full_name: "acme/app"}]} = RepositoryCatalog.list_for_user(user)

      assert captured_resolve_failures(user) == []
    end

    # A listing that failed already reported its own bounded reason.
    # Counting the resulting empty list as an empty grant as well
    # would report one picker open twice, under two different causes.
    test "does not double-report an installation whose listing failed" do
      user = user!()
      link!(installation!(), user)
      stub_error(503)

      assert {:ok, []} = RepositoryCatalog.list_for_user(user)

      assert [%{properties: %{reason: :http_error, http_status: 503}}] =
               captured_resolve_failures(user)
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

  # `Camelot.Github.Client` calls `Req.request/1`, so the only seam is
  # Req's own global default options. Safe because the case is
  # `async: false`: ExUnit runs no other module alongside it.
  defp stub_req(handler) do
    previous = Application.get_env(:req, :default_options, [])
    Req.default_options(plug: {Req.Test, __MODULE__}, retry: false)
    on_exit(fn -> Application.put_env(:req, :default_options, previous) end)

    Req.Test.stub(__MODULE__, handler)
  end

  defp stub_repositories(repositories) do
    stub_req(&Req.Test.json(&1, %{"repositories" => repositories}))
  end

  defp stub_error(status) do
    stub_req(&Plug.Conn.send_resp(&1, status, "nope"))
  end

  defp repository_payload(full_name) do
    [owner, repo] = String.split(full_name, "/")

    %{
      "name" => repo,
      "full_name" => full_name,
      "html_url" => "https://github.com/#{full_name}",
      "private" => false,
      "owner" => %{"login" => owner}
    }
  end

  defp captured_resolve_failures(user) do
    Enum.filter(
      PostHog.Test.all_captured(),
      &(&1.event == "project_repo_resolve_failed" and &1.distinct_id == user.id)
    )
  end

  defp captured_resolve_failure do
    Enum.find(PostHog.Test.all_captured(), &(&1.event == "project_repo_resolve_failed"))
  end
end
