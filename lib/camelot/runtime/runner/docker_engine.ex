defmodule Camelot.Runtime.Runner.DockerEngine do
  @moduledoc """
  DockerEngine runner backend.

  Adapter for the `Runner` behaviour that delegates to
  the per-task design:

    * `start/1` boots an `ExecSession` GenServer, which
      ensures a long-lived `TaskContainer` exists for
      `spec.task_id` and `docker exec`s the agent CLI
      inside it.
    * `stop/1` shuts down the per-session `ExecSession`.
      The TaskContainer keeps running so the next session
      of the same task reuses the workspace.
    * `stop_task/1` removes the container backing the
      task and stops the TaskContainer. Called by
      `AgentProcess` when the task hits a terminal stage.
  """
  @behaviour Camelot.Runtime.Runner

  alias Camelot.Runtime.Runner.DockerEngine.ExecSession
  alias Camelot.Runtime.Runner.DockerEngine.TaskContainer
  alias Camelot.Runtime.Runner.Spec

  @impl true
  def start(%Spec{task_id: nil}), do: {:error, :task_id_required}

  def start(%Spec{} = spec), do: ExecSession.start(spec)

  @impl true
  def stop(handle) when is_pid(handle), do: ExecSession.stop(handle)

  @impl true
  def stop_task(task_id) when is_binary(task_id), do: TaskContainer.stop_task(task_id)
end
