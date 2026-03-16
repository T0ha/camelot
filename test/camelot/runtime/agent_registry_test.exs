defmodule Camelot.Runtime.AgentRegistryTest do
  use ExUnit.Case, async: true

  alias Camelot.Runtime.AgentRegistry

  describe "via/1" do
    test "returns a via tuple" do
      assert {:via, Registry, {AgentRegistry, "abc"}} =
               AgentRegistry.via("abc")
    end
  end

  describe "lookup/1" do
    test "returns nil when not registered" do
      assert AgentRegistry.lookup("nonexistent") == nil
    end

    test "returns pid when registered" do
      name = "test-#{System.unique_integer()}"

      {:ok, _pid} =
        Agent.start_link(fn -> :ok end,
          name: AgentRegistry.via(name)
        )

      assert is_pid(AgentRegistry.lookup(name))
    end
  end
end
