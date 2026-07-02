defmodule Camelot.Runtime.Runner.Swarm.ProxyRouterTest do
  use ExUnit.Case, async: true

  alias Camelot.Runtime.Runner.Swarm.ProxyRouter

  # docker-socket-proxy task shape, trimmed to the fields the
  # resolver reads.
  defp proxy_task(desired, status, node, ip) do
    %{
      "DesiredState" => desired,
      "NodeID" => node,
      "Status" => %{"State" => status},
      "NetworksAttachments" => [%{"Addresses" => ["#{ip}/24"]}]
    }
  end

  describe "proxy_ip_for_node/2" do
    test "returns the overlay IP of the desired-running proxy on the node" do
      tasks = [proxy_task("running", "running", "node-a", "10.0.1.79")]
      assert ProxyRouter.proxy_ip_for_node(tasks, "node-a") == "10.0.1.79"
    end

    test "ignores an orphaned proxy task advertising a stale IP" do
      # A rescheduled proxy leaves an old task that can still report
      # Status.State == "running" with the previous overlay IP.
      # Selecting it would route exec traffic to a dead endpoint.
      orphan = proxy_task("shutdown", "running", "node-a", "10.0.1.91")
      live = proxy_task("running", "running", "node-a", "10.0.1.79")

      assert ProxyRouter.proxy_ip_for_node([orphan, live], "node-a") ==
               "10.0.1.79"
    end

    test "returns nil when no proxy runs on the requested node" do
      tasks = [proxy_task("running", "running", "node-a", "10.0.1.79")]
      assert ProxyRouter.proxy_ip_for_node(tasks, "node-b") == nil
    end

    test "returns nil when the node's proxy is not yet running" do
      tasks = [proxy_task("running", "pending", "node-a", "10.0.1.79")]
      assert ProxyRouter.proxy_ip_for_node(tasks, "node-a") == nil
    end
  end
end
