defmodule Camelot.Runtime.Runner.Swarm do
  @moduledoc """
  Swarm runner backend.

  Adapter for the `Runner` behaviour that delegates to
  the per-task design:

    * `start/1` boots an `ExecSession` GenServer, which
      ensures a long-lived `TaskService` exists for
      `spec.task_id` and `docker exec`s the agent CLI
      inside its container.
    * `stop/1` shuts down the per-session `ExecSession`.
      The TaskService keeps running so the next session
      of the same task reuses the workspace.
    * `stop_task/1` removes the Swarm service backing
      the task and stops the TaskService. Called by
      `AgentProcess` when the task hits a terminal stage.

  Per-node `docker exec` routing goes through
  `Camelot.Runtime.Runner.Swarm.ProxyRouter`, which
  resolves the `docker-socket-proxy` task on the node
  hosting the target container.
  """
  @behaviour Camelot.Runtime.Runner

  alias Camelot.Runtime.Runner.Spec
  alias Camelot.Runtime.Runner.Swarm.ExecSession
  alias Camelot.Runtime.Runner.Swarm.TaskService

  @impl true
  def start(%Spec{task_id: nil}), do: {:error, :task_id_required}

  def start(%Spec{} = spec), do: ExecSession.start(spec)

  @impl true
  def stop(handle) when is_pid(handle), do: ExecSession.stop(handle)

  @impl true
  def stop_task(task_id) when is_binary(task_id), do: TaskService.stop_task(task_id)
end
