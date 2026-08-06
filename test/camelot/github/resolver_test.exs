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
end
