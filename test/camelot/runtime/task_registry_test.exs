defmodule Camelot.Runtime.TaskRegistryTest do
  use ExUnit.Case, async: true

  alias Camelot.Runtime.TaskRegistry

  describe "via/1" do
    test "returns a via tuple" do
      assert {:via, Registry, {TaskRegistry, "abc"}} =
               TaskRegistry.via("abc")
    end
  end

  describe "lookup/1" do
    test "returns nil when not registered" do
      assert TaskRegistry.lookup("nonexistent") == nil
    end

    test "returns pid when registered" do
      name = "test-#{System.unique_integer()}"

      {:ok, _pid} =
        Agent.start_link(fn -> :ok end,
          name: TaskRegistry.via(name)
        )

      assert is_pid(TaskRegistry.lookup(name))
    end
  end
end
