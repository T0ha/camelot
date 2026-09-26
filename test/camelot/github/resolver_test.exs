defmodule Camelot.Github.ResolverTest do
  use ExUnit.Case, async: true

  alias Camelot.Github.Installation
  alias Camelot.Github.Resolver

  describe "installation_id/2" do
    test "is nil when there are no installations" do
      assert is_nil(Resolver.installation_id([], "acme-org"))
    end

    test "matches account_login case-insensitively" do
      installations = [
        %Installation{installation_id: 1, account_login: "acme-org"},
        %Installation{installation_id: 2, account_login: "other-org"}
      ]

      assert Resolver.installation_id(installations, "OTHER-ORG") == 2
    end

    test "falls back to the sole installation when there is no login match" do
      installations = [%Installation{installation_id: 1, account_login: "acme-org"}]

      assert Resolver.installation_id(installations, "unrelated-owner") == 1
    end

    test "falls back to the sole installation when github_owner is nil" do
      installations = [%Installation{installation_id: 1, account_login: "acme-org"}]

      assert Resolver.installation_id(installations, nil) == 1
    end

    test "is nil when several installations exist and none match" do
      installations = [
        %Installation{installation_id: 1, account_login: "acme-org"},
        %Installation{installation_id: 2, account_login: "other-org"}
      ]

      assert is_nil(Resolver.installation_id(installations, "unrelated-owner"))
    end
  end

  describe "owner_coverage/2" do
    test "is :ok when an installation's login matches, case-insensitively" do
      installations = [%Installation{installation_id: 1, account_login: "Acme-Org"}]

      assert Resolver.owner_coverage(installations, "acme-org") == :ok
    end

    test "distinguishes never connected from connected elsewhere" do
      installations = [%Installation{installation_id: 1, account_login: "acme-org"}]

      assert Resolver.owner_coverage([], "acme-org") == {:error, :no_installation}

      assert Resolver.owner_coverage(installations, "unrelated-owner") ==
               {:error, :repo_not_in_installation}
    end

    # The whole point of this function: `installation_id/2` answers
    # "which token do I mint" and so falls back to the sole
    # installation, which is how a project reaches `git clone` with
    # credentials for an account that does not hold the repository.
    # Coverage answers "was this owner ever installed" and must not.
    test "does not inherit installation_id/2's sole-installation fallback" do
      installations = [%Installation{installation_id: 1, account_login: "acme-org"}]

      assert Resolver.installation_id(installations, "unrelated-owner") == 1

      assert Resolver.owner_coverage(installations, "unrelated-owner") ==
               {:error, :repo_not_in_installation}
    end

    test "a project with no repository owner has nothing to resolve" do
      assert Resolver.owner_coverage([], nil) == :ok
    end
  end
end
