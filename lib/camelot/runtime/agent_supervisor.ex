defmodule Camelot.Runtime.AgentSupervisor do
  @moduledoc """
  DynamicSupervisor for AgentProcess GenServers.
  Each agent gets one supervised process that manages
  CLI Port execution.
  """
  use DynamicSupervisor

  alias Camelot.Runtime.AgentProcess
  alias Camelot.Runtime.AgentRegistry

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

  @spec start_agent(String.t()) ::
          DynamicSupervisor.on_start_child()
  def start_agent(agent_id) do
    DynamicSupervisor.start_child(
      __MODULE__,
      {AgentProcess, agent_id: agent_id}
    )
  end

  @spec stop_agent(String.t()) :: :ok | {:error, :not_found}
  def stop_agent(agent_id) do
    case AgentRegistry.lookup(agent_id) do
      nil ->
        {:error, :not_found}

      pid ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)
    end
  end
end
