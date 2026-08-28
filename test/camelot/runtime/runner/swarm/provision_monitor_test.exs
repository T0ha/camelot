defmodule Camelot.Runtime.Runner.Swarm.ProvisionMonitorTest do
  use ExUnit.Case, async: true

  alias Camelot.Runtime.Runner.Swarm.ProvisionMonitor

  # Docker `GET /tasks` shape, trimmed to the fields the describer
  # reads.
  defp swarm_task(state, opts \\ []) do
    %{
      "CreatedAt" => Keyword.get(opts, :created_at, "2026-08-28T09:20:00.000000000Z"),
      "DesiredState" => Keyword.get(opts, :desired, "running"),
      "NodeID" => Keyword.get(opts, :node, "node-a"),
      "Status" =>
        %{
          "State" => state,
          "ContainerStatus" => %{
            "ContainerID" => Keyword.get(opts, :cid, "container-a")
          }
        }
        |> put_optional("Err", Keyword.get(opts, :err))
        |> put_optional("Message", Keyword.get(opts, :message))
    }
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  # Docker's multiplexed log frame: stream byte, 3 pad bytes,
  # 32-bit big-endian size, payload.
  defp frame(payload) do
    <<2, 0, 0, 0, byte_size(payload)::32-big>> <> payload
  end

  describe "describe_tasks/1" do
    test "an empty task list means the service is not scheduled yet" do
      assert {:provisioning, message} = ProvisionMonitor.describe_tasks([])
      assert message =~ "runner service"
    end

    test "a pending replica reports scheduling" do
      assert {:provisioning, message} =
               ProvisionMonitor.describe_tasks([swarm_task("pending")])

      assert message =~ "Scheduling"
    end

    test "a pending replica surfaces the scheduler's error" do
      task = swarm_task("pending", err: "no suitable node (insufficient memory)")

      assert {:provisioning, message} = ProvisionMonitor.describe_tasks([task])
      assert message =~ "no suitable node (insufficient memory)"
    end

    test "a preparing replica reports the image pull" do
      assert {:pulling_image, message} =
               ProvisionMonitor.describe_tasks([swarm_task("preparing")])

      assert message =~ "image"
    end

    test "a starting replica reports the container start" do
      assert {:starting, message} =
               ProvisionMonitor.describe_tasks([swarm_task("starting")])

      assert message =~ "Starting"
    end

    test "a running replica hands back its placement so logs can be tailed" do
      assert {:running, "container-a", "node-a"} =
               ProvisionMonitor.describe_tasks([swarm_task("running")])
    end

    test "a failed replica reports the failure and that Swarm retries" do
      task = swarm_task("failed", err: "task: non-zero exit (1)")

      assert {:provisioning, message} = ProvisionMonitor.describe_tasks([task])
      assert message =~ "non-zero exit (1)"
    end

    # Swarm keeps historical task records; an orphaned replica from a
    # previous placement must not mask the current one (the same trap
    # `ExecSession.pick_running_task/1` guards against).
    test "the newest replica wins over historical records" do
      old =
        swarm_task("shutdown",
          created_at: "2026-08-28T09:00:00.000000000Z",
          desired: "shutdown"
        )

      new = swarm_task("preparing", created_at: "2026-08-28T09:20:00.000000000Z")

      assert {:pulling_image, _} = ProvisionMonitor.describe_tasks([old, new])
      assert {:pulling_image, _} = ProvisionMonitor.describe_tasks([new, old])
    end

    test "a running replica without a container id keeps waiting" do
      assert {:starting, _message} =
               ProvisionMonitor.describe_tasks([swarm_task("running", cid: nil)])
    end
  end

  describe "entrypoint_line/1" do
    test "returns the last entrypoint line from a multiplexed log tail" do
      logs =
        frame("[entrypoint] cloning https://github.com/acme/app into /workspace\n") <>
          frame("[entrypoint] asdf install (from .tool-versions)\n")

      assert ProvisionMonitor.entrypoint_line(logs) ==
               "asdf install (from .tool-versions)"
    end

    test "ignores non-entrypoint noise" do
      logs = frame("Cloning into '.'...\n") <> frame("remote: Enumerating objects\n")

      assert ProvisionMonitor.entrypoint_line(logs) == nil
    end

    test "reads plain (non-multiplexed) log bytes too" do
      assert ProvisionMonitor.entrypoint_line("[entrypoint] cloning x into /workspace\n") ==
               "cloning x into /workspace"
    end

    test "no logs yet" do
      assert ProvisionMonitor.entrypoint_line("") == nil
    end
  end

  describe "workspace_progress/1" do
    test "falls back to a generic line without entrypoint output" do
      assert {:workspace, message} = ProvisionMonitor.workspace_progress(nil)
      assert message =~ "workspace"
    end

    test "surfaces what the entrypoint is doing" do
      assert {:workspace, message} =
               ProvisionMonitor.workspace_progress("asdf install (from .tool-versions)")

      assert message =~ "asdf install (from .tool-versions)"
    end
  end
end
