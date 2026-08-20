defmodule Camelot.Runtime.TaskRunnerSupervisor do
  @moduledoc """
  DynamicSupervisor for TaskRunner GenServers.
  Each in-flight task gets one supervised process that manages
  CLI Port execution across its stages and retries.
  """
  use DynamicSupervisor

  alias Camelot.Runtime.TaskRegistry
  alias Camelot.Runtime.TaskRunner

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    DynamicSupervisor.start_link(
      __MODULE__,
      opts,
      name: __MODULE__
    )
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @spec start_task_runner(String.t()) ::
          DynamicSupervisor.on_start_child()
  def start_task_runner(task_id) do
    DynamicSupervisor.start_child(
      __MODULE__,
      {TaskRunner, task_id: task_id}
    )
  end

  @spec stop_task_runner(String.t()) :: :ok | {:error, :not_found}
  def stop_task_runner(task_id) do
    case TaskRegistry.lookup(task_id) do
      nil ->
        {:error, :not_found}

      pid ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)
    end
  end
end
