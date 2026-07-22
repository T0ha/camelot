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

  describe "drop_stale_node_proxy/2 (self-healing step)" do
    @cache_key {ProxyRouter, :proxy_ips}

    setup do
      on_exit(fn -> :persistent_term.erase(@cache_key) end)
      :ok
    end

    test "drops only the failing node's cached IP on a transport error" do
      :persistent_term.put(@cache_key, %{"node-a" => "10.0.1.19", "node-b" => "10.0.1.20"})
      err = %Req.TransportError{reason: :ehostunreach}

      assert ProxyRouter.drop_stale_node_proxy({%Req.Request{}, err}, "node-a") ==
               {%Req.Request{}, err}

      cache = :persistent_term.get(@cache_key)
      refute Map.has_key?(cache, "node-a")
      assert cache["node-b"] == "10.0.1.20"
    end

    test "drops the node's cached IP on a 503 response" do
      :persistent_term.put(@cache_key, %{"node-a" => "10.0.1.19"})

      ProxyRouter.drop_stale_node_proxy({%Req.Request{}, %Req.Response{status: 503}}, "node-a")

      refute Map.has_key?(:persistent_term.get(@cache_key), "node-a")
    end

    test "keeps the node's cached IP on a healthy response" do
      :persistent_term.put(@cache_key, %{"node-a" => "10.0.1.19"})

      ProxyRouter.drop_stale_node_proxy({%Req.Request{}, %Req.Response{status: 200}}, "node-a")

      assert :persistent_term.get(@cache_key)["node-a"] == "10.0.1.19"
    end
  end
end
