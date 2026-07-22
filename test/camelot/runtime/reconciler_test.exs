defmodule Camelot.Runtime.ReconcilerTest do
  use ExUnit.Case, async: true

  alias Camelot.Runtime.Reconciler
  alias Camelot.Runtime.Runner.LocalPort
  alias Camelot.Runtime.Runner.Swarm

  describe "recovery_action/4" do
    test "adopts a running task session when its runner is present" do
      assert :adopt = Reconciler.recovery_action(Swarm, :task, "svc123", :present)
    end

    test "fails when the runner container is gone" do
      assert :fail = Reconciler.recovery_action(Swarm, :task, "svc123", :gone)
    end

    test "fails when the service exists but has no running tasks" do
      assert :fail = Reconciler.recovery_action(Swarm, :task, "svc123", :no_tasks)
    end

    test "fails when the runner state is unknown" do
      assert :fail = Reconciler.recovery_action(Swarm, :task, "svc123", :unknown)
    end

    test "never adopts a bootstrap session (nothing to finalise)" do
      assert :fail = Reconciler.recovery_action(Swarm, :bootstrap, "svc123", :present)
    end

    test "fails when there is no runner handle to probe" do
      assert :fail = Reconciler.recovery_action(Swarm, :task, nil, :present)
    end

    test "never adopts on the LocalPort backend (no container)" do
      assert :fail = Reconciler.recovery_action(LocalPort, :task, "svc123", :present)
    end
  end

  describe "doomed_adoption?/2" do
    defp dt(iso), do: elem(DateTime.from_iso8601(iso), 1)

    test "doomed when the live container was replaced after the exec began" do
      # The incident: exec started 10:44, container rescheduled 12:47.
      assert Reconciler.doomed_adoption?(
               dt("2026-07-14T12:47:00Z"),
               dt("2026-07-14T10:44:00Z")
             )
    end

    test "adoptable when the container predates the exec (same container)" do
      refute Reconciler.doomed_adoption?(
               dt("2026-07-14T10:40:00Z"),
               dt("2026-07-14T10:44:00Z")
             )
    end

    test "adoptable when the container start time is unknown" do
      # No timestamp -> proceed; ExecSession's wall-clock budget still
      # bounds the poll.
      refute Reconciler.doomed_adoption?(nil, dt("2026-07-14T10:44:00Z"))
    end
  end
end
