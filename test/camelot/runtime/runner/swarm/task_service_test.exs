defmodule Camelot.Runtime.Runner.Swarm.TaskServiceTest do
  # Mutates the global :runner app env, so it can't run async.
  use ExUnit.Case, async: false

  alias Camelot.Runtime.Runner.Spec
  alias Camelot.Runtime.Runner.Swarm.SelfNetworks
  alias Camelot.Runtime.Runner.Swarm.TaskService

  setup do
    original = Application.get_env(:camelot, :runner)
    on_exit(fn -> Application.put_env(:camelot, :runner, original) end)
    :ok
  end

  defp put_networks(networks) do
    runner = Application.get_env(:camelot, :runner, [])
    Application.put_env(:camelot, :runner, Keyword.put(runner, :networks, networks))
  end

  defp spec do
    %Spec{
      session_id: "sess-1",
      owner_pid: self(),
      argv: [],
      task_id: "task-1",
      image: "ghcr.io/example/runner"
    }
  end

  describe "service_create_payload/2 — networks" do
    test "omits Networks when the list is empty" do
      put_networks([])

      payload = TaskService.service_create_payload(spec(), "camelot-task-task-1")

      refute Map.has_key?(payload["TaskTemplate"], "Networks")
    end

    test "none keeps runners isolated (no Networks)" do
      put_networks(["none"])

      payload = TaskService.service_create_payload(spec(), "camelot-task-task-1")

      refute Map.has_key?(payload["TaskTemplate"], "Networks")
    end

    test "attaches each configured overlay network as a Target" do
      put_networks(["captain-overlay-network", "extra-net"])

      payload = TaskService.service_create_payload(spec(), "camelot-task-task-1")

      assert payload["TaskTemplate"]["Networks"] == [
               %{"Target" => "captain-overlay-network"},
               %{"Target" => "extra-net"}
             ]
    end

    test "keeps the rest of the task template intact" do
      put_networks(["captain-overlay-network"])

      payload = TaskService.service_create_payload(spec(), "camelot-task-task-1")
      template = payload["TaskTemplate"]

      assert payload["Name"] == "camelot-task-task-1"
      # Bounded retries, not "none": a single failed start must not
      # strand the service at zero replicas with nothing to revive it.
      assert template["RestartPolicy"]["Condition"] == "on-failure"
      assert template["RestartPolicy"]["MaxAttempts"] == 3
      assert template["ContainerSpec"]["Image"] == "ghcr.io/example/runner"
    end

    test "auto resolves to the discovered networks" do
      SelfNetworks.put_cache(["discovered-net"])
      on_exit(&SelfNetworks.reset_cache/0)
      put_networks(["auto"])

      payload = TaskService.service_create_payload(spec(), "camelot-task-task-1")

      assert payload["TaskTemplate"]["Networks"] == [%{"Target" => "discovered-net"}]
    end

    test "auto merges discovered networks with explicit extras" do
      SelfNetworks.put_cache(["discovered-net"])
      on_exit(&SelfNetworks.reset_cache/0)
      put_networks(["auto", "extra-net"])

      payload = TaskService.service_create_payload(spec(), "camelot-task-task-1")

      assert payload["TaskTemplate"]["Networks"] == [
               %{"Target" => "discovered-net"},
               %{"Target" => "extra-net"}
             ]
    end
  end

  describe "plan_pinned_update/3" do
    defp service_spec(image) do
      %{"TaskTemplate" => %{"ContainerSpec" => %{"Image" => image, "Command" => ["sleep"]}}}
    end

    test "pins a floating :latest tag to the newly resolved digest" do
      spec = service_spec("ghcr.io/acme/runner:latest@sha256:old")

      assert {:update, new_spec} =
               TaskService.plan_pinned_update(spec, "ghcr.io/acme/runner:latest@sha256:old", "sha256:new")

      assert get_in(new_spec, ["TaskTemplate", "ContainerSpec", "Image"]) ==
               "ghcr.io/acme/runner:latest@sha256:new"

      # unrelated fields survive untouched
      assert get_in(new_spec, ["TaskTemplate", "ContainerSpec", "Command"]) == ["sleep"]
    end

    test "pins a bare (untagged, undigested) image to the resolved digest" do
      spec = service_spec("ghcr.io/acme/runner")

      assert {:update, new_spec} = TaskService.plan_pinned_update(spec, "ghcr.io/acme/runner", "sha256:new")

      assert get_in(new_spec, ["TaskTemplate", "ContainerSpec", "Image"]) ==
               "ghcr.io/acme/runner@sha256:new"
    end

    test "is a no-op when the service already runs the resolved digest" do
      spec = service_spec("ghcr.io/acme/runner:latest@sha256:same")

      assert :unchanged =
               TaskService.plan_pinned_update(spec, "ghcr.io/acme/runner:latest@sha256:same", "sha256:same")
    end
  end
end
