defmodule CamelotWeb.AgentLive.Index do
  @moduledoc """
  LiveView listing all agents with status indicators.
  """
  use CamelotWeb, :live_view

  alias Camelot.Agents.Agent

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      for agent <- Ash.read!(Agent) do
        Phoenix.PubSub.subscribe(
          Camelot.PubSub,
          "agent:#{agent.id}"
        )
      end
    end

    {:ok, load_agents(socket)}
  end

  @impl true
  def handle_info({:agent_updated, _agent}, socket) do
    {:noreply, load_agents(socket)}
  end

  defp load_agents(socket) do
    agents = Ash.read!(Agent, load: [:project])

    assign(socket,
      page_title: "Agents",
      agents: agents
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-bold">Agents</h1>
      </div>

      <div
        :if={@agents == []}
        class="text-center py-12 text-base-content/50"
      >
        No agents configured yet.
        Create a project and assign an agent to it.
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
        <.link
          :for={agent <- @agents}
          navigate={~p"/agents/#{agent.id}"}
          class="card bg-base-200 hover:shadow-md transition-shadow"
        >
          <div class="card-body p-4">
            <div class="flex items-center justify-between">
              <h2 class="card-title text-base">
                {agent.name}
              </h2>
              <span class={[
                "badge badge-sm",
                agent.status == :idle && "badge-success",
                agent.status == :busy && "badge-warning"
              ]}>
                {agent.status}
              </span>
            </div>
            <p class="text-sm text-base-content/60">
              {agent.type}
            </p>
            <p
              :if={Ash.Resource.loaded?(agent, :project)}
              class="text-xs text-base-content/50"
            >
              {agent.project.name}
            </p>
          </div>
        </.link>
      </div>
    </div>
    """
  end
end
