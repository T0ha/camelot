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

  describe "pinned_ref/2" do
    defp resolves(digest), do: fn _image -> {:ok, digest} end
    defp fails(reason), do: fn _image -> {:error, reason} end

    test "pins a floating tag to the resolved digest" do
      assert RegistryClient.pinned_ref(
               "ghcr.io/acme/runner:latest",
               resolves("sha256:new")
             ) == "ghcr.io/acme/runner:latest@sha256:new"
    end

    test "pins an untagged reference" do
      assert RegistryClient.pinned_ref("ghcr.io/acme/runner", resolves("sha256:new")) ==
               "ghcr.io/acme/runner@sha256:new"
    end

    test "leaves a deliberately pinned tag untouched without asking the registry" do
      never = fn _ -> flunk("should not resolve a pinned reference") end

      assert RegistryClient.pinned_ref("ghcr.io/acme/runner:1.19", never) ==
               "ghcr.io/acme/runner:1.19"
    end

    test "falls back to the floating tag when the registry is unreachable" do
      assert RegistryClient.pinned_ref("ghcr.io/acme/runner:latest", fails(:nxdomain)) ==
               "ghcr.io/acme/runner:latest"
    end

    test "passes nil through" do
      assert RegistryClient.pinned_ref(nil) == nil
    end
  end
end
