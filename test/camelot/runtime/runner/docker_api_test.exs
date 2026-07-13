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
end
