defmodule Camelot.Runtime.Runner.DockerApiTest do
  use ExUnit.Case, async: true

  alias Camelot.Runtime.Runner.DockerApi

  describe "extract_node_labels/1" do
    test "collects the camelot-home label from each node" do
      nodes = [
        %{"Spec" => %{"Labels" => %{"camelot-home" => "node-b"}}},
        %{"Spec" => %{"Labels" => %{"camelot-home" => "node-a"}}}
      ]

      assert DockerApi.extract_node_labels(nodes) == ["node-a", "node-b"]
    end

    test "dedupes repeated label values" do
      nodes = [
        %{"Spec" => %{"Labels" => %{"camelot-home" => "node-a"}}},
        %{"Spec" => %{"Labels" => %{"camelot-home" => "node-a"}}}
      ]

      assert DockerApi.extract_node_labels(nodes) == ["node-a"]
    end

    test "skips nodes without the camelot-home label" do
      nodes = [
        %{"Spec" => %{"Labels" => %{}}},
        %{"Spec" => %{"Labels" => %{"other" => "x"}}},
        %{"Spec" => %{}}
      ]

      assert DockerApi.extract_node_labels(nodes) == []
    end

    test "skips a blank camelot-home label" do
      nodes = [%{"Spec" => %{"Labels" => %{"camelot-home" => ""}}}]

      assert DockerApi.extract_node_labels(nodes) == []
    end

    test "returns an empty list for an empty node list" do
      assert DockerApi.extract_node_labels([]) == []
    end
  end

  describe "stale_proxy?/1" do
    test "true for a 503 response (cached IP is a worker proxy)" do
      assert DockerApi.stale_proxy?(%Req.Response{status: 503})
    end

    test "false for a healthy response" do
      refute DockerApi.stale_proxy?(%Req.Response{status: 200})
      refute DockerApi.stale_proxy?(%Req.Response{status: 404})
    end

    test "true for any transport error (rescheduled proxy, new overlay IP)" do
      for reason <- [:ehostunreach, :timeout, :econnrefused, :closed, :nxdomain] do
        assert DockerApi.stale_proxy?(%Req.TransportError{reason: reason}),
               "expected #{reason} to be treated as a stale proxy"
      end
    end

    test "false for unrelated exceptions" do
      refute DockerApi.stale_proxy?(%RuntimeError{message: "boom"})
    end
  end

  describe "drop_stale_manager_proxy/1 (self-healing step)" do
    @manager_key {DockerApi, :manager_proxy_ip}

    setup do
      on_exit(fn -> :persistent_term.erase(@manager_key) end)
      :ok
    end

    test "drops the cached IP on :ehostunreach and passes the result through" do
      :persistent_term.put(@manager_key, "10.0.1.11")
      err = %Req.TransportError{reason: :ehostunreach}

      assert DockerApi.drop_stale_manager_proxy({%Req.Request{}, err}) ==
               {%Req.Request{}, err}

      assert :persistent_term.get(@manager_key, :dropped) == :dropped
    end

    test "drops the cached IP on a 503 response" do
      :persistent_term.put(@manager_key, "10.0.1.11")
      resp = %Req.Response{status: 503}

      DockerApi.drop_stale_manager_proxy({%Req.Request{}, resp})

      assert :persistent_term.get(@manager_key, :dropped) == :dropped
    end

    test "keeps the cached IP on a healthy response" do
      :persistent_term.put(@manager_key, "10.0.1.11")

      DockerApi.drop_stale_manager_proxy({%Req.Request{}, %Req.Response{status: 200}})

      assert :persistent_term.get(@manager_key, :dropped) == "10.0.1.11"
    end
  end
end
