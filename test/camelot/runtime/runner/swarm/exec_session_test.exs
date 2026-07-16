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

  describe "adopt_action/4" do
    # The reconciler adopts a `:running` session after a restart by
    # re-attaching to the still-alive runner container and polling for
    # the exec-wrapper's completion marker. If the container was
    # *replaced* (Swarm reschedule / OOM on a tiny node) after the
    # session's exec began, the marker lived in the prior container's
    # /tmp and can never appear — polling must give up rather than hang
    # forever (the regression that stranded a task in `executing`).
    defp dt(iso), do: elem(DateTime.from_iso8601(iso), 1)

    test "keeps polling while the container predates the session exec" do
      # Container booted before the session started -> same container the
      # exec ran in; its marker is still recoverable.
      container = dt("2026-07-14T10:40:00Z")
      session = dt("2026-07-14T10:44:00Z")

      assert ExecSession.adopt_action(container, session, 0, 900_000) == :poll
    end

    test "gives up when the container was replaced after the session exec" do
      # The actual incident: container rescheduled at 12:47, session exec
      # began at 10:44 -> marker unrecoverable.
      container = dt("2026-07-14T12:47:00Z")
      session = dt("2026-07-14T10:44:00Z")

      assert ExecSession.adopt_action(container, session, 0, 900_000) ==
               {:give_up, :container_replaced}
    end

    test "gives up once the wall-clock budget is exhausted" do
      # Backstop for missing/again-skewed timestamps: never poll forever.
      assert ExecSession.adopt_action(nil, nil, 900_000, 900_000) ==
               {:give_up, :timeout}
    end

    test "polls within budget when timestamps are unavailable" do
      assert ExecSession.adopt_action(nil, nil, 1_000, 900_000) == :poll
    end
  end

  describe "container_replaced?/2" do
    defp t(iso), do: elem(DateTime.from_iso8601(iso), 1)

    test "true when the container started strictly after the session" do
      assert ExecSession.container_replaced?(
               t("2026-07-14T12:47:00Z"),
               t("2026-07-14T10:44:00Z")
             )
    end

    test "false when the container started before the session" do
      refute ExecSession.container_replaced?(
               t("2026-07-14T10:40:00Z"),
               t("2026-07-14T10:44:00Z")
             )
    end

    test "false when either timestamp is missing" do
      refute ExecSession.container_replaced?(nil, t("2026-07-14T10:44:00Z"))
      refute ExecSession.container_replaced?(t("2026-07-14T10:44:00Z"), nil)
    end
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
