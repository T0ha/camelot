defmodule Camelot.Runtime.AgentRegistry do
  @moduledoc """
  Registry for named lookup of AgentProcess GenServers.
  Each agent is registered as `{AgentRegistry, agent_id}`.
  """

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    Registry.child_spec(
      keys: :unique,
      name: __MODULE__
    )
  end

  @spec via(String.t()) :: {:via, Registry, {__MODULE__, String.t()}}
  def via(agent_id) do
    {:via, Registry, {__MODULE__, agent_id}}
  end

  @spec lookup(String.t()) :: pid() | nil
  def lookup(agent_id) do
    case Registry.lookup(__MODULE__, agent_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end
end
