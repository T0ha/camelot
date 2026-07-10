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
end
