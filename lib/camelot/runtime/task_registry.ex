defmodule Camelot.Runtime.TaskRegistry do
  @moduledoc """
  Registry for named lookup of TaskRunner GenServers.
  Each task is registered as `{TaskRegistry, task_id}`.
  """

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    Registry.child_spec(
      keys: :unique,
      name: __MODULE__
    )
  end

  @spec via(String.t()) :: {:via, Registry, {__MODULE__, String.t()}}
  def via(task_id) do
    {:via, Registry, {__MODULE__, task_id}}
  end

  @spec lookup(String.t()) :: pid() | nil
  def lookup(task_id) do
    case Registry.lookup(__MODULE__, task_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end
end
