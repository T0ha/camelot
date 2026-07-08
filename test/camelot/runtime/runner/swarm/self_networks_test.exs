defmodule Camelot.Runtime.Runner.Swarm.SelfNetworksTest do
  use ExUnit.Case, async: true

  alias Camelot.Runtime.Runner.Swarm.SelfNetworks

  describe "find_own_service_id/2" do
    test "matches the task whose full container id is prefixed by the short id" do
      tasks = [
        %{"ServiceID" => "svc-other", "Status" => %{"ContainerStatus" => %{"ContainerID" => "aaaa1111zzzz"}}},
        %{"ServiceID" => "svc-self", "Status" => %{"ContainerStatus" => %{"ContainerID" => "60910a6e58a7deadbeef"}}}
      ]

      assert SelfNetworks.find_own_service_id(tasks, "60910a6e58a7") == "svc-self"
    end

    test "returns nil when no container id matches" do
      tasks = [
        %{"ServiceID" => "svc-other", "Status" => %{"ContainerStatus" => %{"ContainerID" => "ffffffff"}}}
      ]

      assert SelfNetworks.find_own_service_id(tasks, "60910a6e58a7") == nil
    end

    test "returns nil for an empty container id (never matches everything)" do
      tasks = [%{"ServiceID" => "svc", "Status" => %{"ContainerStatus" => %{"ContainerID" => "abc"}}}]

      assert SelfNetworks.find_own_service_id(tasks, "") == nil
    end

    test "tolerates tasks missing container status" do
      tasks = [%{"ServiceID" => "svc"}, %{"ServiceID" => "svc2", "Status" => %{}}]

      assert SelfNetworks.find_own_service_id(tasks, "abc") == nil
    end
  end

  describe "targets_from_service/1" do
    test "extracts the service's own network targets" do
      service = %{
        "Spec" => %{
          "TaskTemplate" => %{
            "Networks" => [%{"Target" => "netid-1"}, %{"Target" => "netid-2"}]
          }
        }
      }

      assert SelfNetworks.targets_from_service(service) == ["netid-1", "netid-2"]
    end

    test "returns [] when the service has no networks" do
      assert SelfNetworks.targets_from_service(%{"Spec" => %{"TaskTemplate" => %{}}}) == []
      assert SelfNetworks.targets_from_service(%{}) == []
    end

    test "drops entries without a Target" do
      service = %{"Spec" => %{"TaskTemplate" => %{"Networks" => [%{"Target" => "ok"}, %{}]}}}

      assert SelfNetworks.targets_from_service(service) == ["ok"]
    end
  end

  describe "discover/0 memoization" do
    test "serves a seeded cache without hitting Docker" do
      SelfNetworks.put_cache(["cached-net"])
      on_exit(&SelfNetworks.reset_cache/0)

      assert SelfNetworks.discover() == ["cached-net"]
    end
  end
end
