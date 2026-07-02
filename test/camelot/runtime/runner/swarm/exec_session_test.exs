defmodule Camelot.Runtime.Runner.Swarm.ExecSessionTest do
  use ExUnit.Case, async: true

  alias Camelot.Runtime.Runner.Swarm.ExecSession

  # Docker `GET /tasks` task shape, trimmed to the fields the
  # picker reads.
  defp task(desired, status, opts \\ []) do
    %{
      "DesiredState" => desired,
      "NodeID" => Keyword.get(opts, :node, "node-a"),
      "Status" => %{
        "State" => status,
        "ContainerStatus" => %{
          "ContainerID" => Keyword.get(opts, :cid, "container-a")
        }
      }
    }
  end

  describe "pick_running_task/1" do
    test "picks the desired-running, status-running placement" do
      tasks = [task("running", "running", node: "node-live", cid: "cid-live")]

      assert ExecSession.pick_running_task(tasks) ==
               {:ok, "cid-live", "node-live"}
    end

    test "ignores an orphaned replica still reporting status running" do
      # The regression: a shut-down replica on an unreachable node
      # lingers in Status.State == "running" and is listed first.
      # The live placement must still be chosen.
      orphan = task("shutdown", "running", node: "node-dead", cid: "cid-dead")
      live = task("running", "running", node: "node-live", cid: "cid-live")

      assert ExecSession.pick_running_task([orphan, live]) ==
               {:ok, "cid-live", "node-live"}
    end

    test "is :pending when the only task is desired-shutdown" do
      assert ExecSession.pick_running_task([task("shutdown", "running")]) ==
               :pending
    end

    test "is :pending when the desired-running task has not started" do
      assert ExecSession.pick_running_task([task("running", "pending")]) ==
               :pending
    end

    test "skips a task without a container id yet" do
      no_cid = task("running", "running", cid: nil)
      assert ExecSession.pick_running_task([no_cid]) == :pending
    end

    test "is :pending for an empty task list" do
      assert ExecSession.pick_running_task([]) == :pending
    end
  end
end
