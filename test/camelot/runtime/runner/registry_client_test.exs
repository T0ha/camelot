defmodule Camelot.Runtime.Runner.RegistryClientTest do
  use ExUnit.Case, async: true

  alias Camelot.Runtime.Runner.RegistryClient

  describe "parse_bearer_challenge/1" do
    test "parses a ghcr Bearer challenge into its parameters" do
      header =
        ~s(Bearer realm="https://ghcr.io/token",service="ghcr.io",scope="repository:t0ha/camelot-runner-elixir:pull")

      assert RegistryClient.parse_bearer_challenge(header) == %{
               "realm" => "https://ghcr.io/token",
               "service" => "ghcr.io",
               "scope" => "repository:t0ha/camelot-runner-elixir:pull"
             }
    end

    test "returns an empty map when there are no key=\"value\" pairs" do
      assert RegistryClient.parse_bearer_challenge("Bearer") == %{}
    end
  end

  describe "split_host_repo/1" do
    test "treats a first segment with a dot as the registry host" do
      assert RegistryClient.split_host_repo("ghcr.io/t0ha/camelot-runner-elixir") ==
               {"ghcr.io", "t0ha/camelot-runner-elixir"}
    end

    test "treats a first segment with a port as the registry host" do
      assert RegistryClient.split_host_repo("registry:5000/acme/runner") ==
               {"registry:5000", "acme/runner"}
    end

    test "defaults the registry and library/ prefix for a bare name" do
      assert RegistryClient.split_host_repo("postgres") ==
               {"registry-1.docker.io", "library/postgres"}
    end

    test "defaults the registry for an unqualified namespaced name" do
      assert RegistryClient.split_host_repo("acme/runner") ==
               {"registry-1.docker.io", "acme/runner"}
    end
  end
end
