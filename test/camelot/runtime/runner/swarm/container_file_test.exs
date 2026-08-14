defmodule Camelot.Runtime.Runner.Swarm.ContainerFileTest do
  use ExUnit.Case, async: true

  alias Camelot.Runtime.Runner.Swarm.ContainerFile

  describe "expand_home/1" do
    test "expands a leading ~ to the in-container agent home" do
      assert ContainerFile.expand_home("~/.claude/plans/x.md") ==
               "/home/agent/.claude/plans/x.md"
    end

    test "leaves absolute paths untouched" do
      assert ContainerFile.expand_home("/home/agent/.claude/plans/x.md") ==
               "/home/agent/.claude/plans/x.md"
    end
  end
end
