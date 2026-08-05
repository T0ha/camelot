defmodule Camelot.Runtime.Runner.ImageRefTest do
  use ExUnit.Case, async: true

  alias Camelot.Runtime.Runner.ImageRef

  describe "parse/1" do
    test "bare name (no tag, no digest)" do
      assert ImageRef.parse("ghcr.io/t0ha/camelot-runner-elixir") ==
               %{name: "ghcr.io/t0ha/camelot-runner-elixir", tag: nil, digest: nil}
    end

    test "name with tag" do
      assert ImageRef.parse("ghcr.io/t0ha/camelot-runner-elixir:1.19") ==
               %{name: "ghcr.io/t0ha/camelot-runner-elixir", tag: "1.19", digest: nil}
    end

    test "name with tag and digest" do
      assert ImageRef.parse("ghcr.io/t0ha/camelot-runner-elixir:latest@sha256:abc123") ==
               %{
                 name: "ghcr.io/t0ha/camelot-runner-elixir",
                 tag: "latest",
                 digest: "sha256:abc123"
               }
    end

    test "name with digest only" do
      assert ImageRef.parse("ghcr.io/t0ha/camelot-runner-elixir@sha256:abc123") ==
               %{name: "ghcr.io/t0ha/camelot-runner-elixir", tag: nil, digest: "sha256:abc123"}
    end

    test "registry host with a port is not mistaken for a tag" do
      assert ImageRef.parse("registry:5000/acme/runner") ==
               %{name: "registry:5000/acme/runner", tag: nil, digest: nil}
    end

    test "registry host with a port plus a real tag" do
      assert ImageRef.parse("registry:5000/acme/runner:1.2") ==
               %{name: "registry:5000/acme/runner", tag: "1.2", digest: nil}
    end
  end

  describe "floating?/1" do
    test "bare name is floating" do
      assert ImageRef.floating?("ghcr.io/t0ha/camelot-runner-elixir")
    end

    test "latest tag is floating" do
      assert ImageRef.floating?("ghcr.io/t0ha/camelot-runner-elixir:latest")
    end

    test "latest tag with a digest is still floating (digest is re-resolvable)" do
      assert ImageRef.floating?("ghcr.io/t0ha/camelot-runner-elixir:latest@sha256:abc")
    end

    test "explicit version tag is pinned" do
      refute ImageRef.floating?("ghcr.io/t0ha/camelot-runner-elixir:1.19")
    end

    test "digest-only reference is pinned" do
      refute ImageRef.floating?("ghcr.io/t0ha/camelot-runner-elixir@sha256:abc")
    end

    test "registry-port bare name is floating" do
      assert ImageRef.floating?("registry:5000/acme/runner")
    end
  end

  describe "without_digest/1" do
    test "strips a digest, keeping the tag" do
      assert ImageRef.without_digest("ghcr.io/acme/runner:latest@sha256:abc") ==
               "ghcr.io/acme/runner:latest"
    end

    test "strips a digest from a tagless reference" do
      assert ImageRef.without_digest("ghcr.io/acme/runner@sha256:abc") ==
               "ghcr.io/acme/runner"
    end

    test "is a no-op when there is no digest" do
      assert ImageRef.without_digest("ghcr.io/acme/runner:latest") ==
               "ghcr.io/acme/runner:latest"
    end
  end

  describe "pin/2" do
    test "appends a digest to a tagged reference" do
      assert ImageRef.pin("ghcr.io/acme/runner:latest", "sha256:abc") ==
               "ghcr.io/acme/runner:latest@sha256:abc"
    end

    test "replaces an existing digest, keeping the tag" do
      assert ImageRef.pin("ghcr.io/acme/runner:latest@sha256:old", "sha256:new") ==
               "ghcr.io/acme/runner:latest@sha256:new"
    end

    test "pins a bare name" do
      assert ImageRef.pin("ghcr.io/acme/runner", "sha256:abc") ==
               "ghcr.io/acme/runner@sha256:abc"
    end
  end
end
