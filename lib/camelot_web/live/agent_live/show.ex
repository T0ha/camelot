defmodule CamelotWeb.AgentLive.Show do
  @moduledoc """
  Agent detail LiveView with status and session history.
  """
  use CamelotWeb, :live_view

  alias Camelot.Agents.Agent

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    agent = Ash.get!(Agent, id, load: [:project, :sessions])

    if connected?(socket) do
      Phoenix.PubSub.subscribe(
        Camelot.PubSub,
        "agent:#{id}"
      )
    end

    {:ok,
     assign(socket,
       page_title: agent.name,
       agent: agent
     )}
  end

  @impl true
  def handle_info({:agent_updated, agent}, socket) do
    agent = Ash.load!(agent, [:project, :sessions])
    {:noreply, assign(socket, agent: agent)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <div>
          <.link
            navigate={~p"/agents"}
            class="text-sm text-base-content/60"
          >
            &larr; Back to agents
          </.link>
          <h1 class="text-2xl font-bold">{@agent.name}</h1>
        </div>
        <span class={[
          "badge",
          @agent.status == :idle && "badge-success",
          @agent.status == :busy && "badge-warning"
        ]}>
          {@agent.status}
        </span>
      </div>

      <.list>
        <:item title="Type">{@agent.type}</:item>
        <:item title="Project">
          {if Ash.Resource.loaded?(@agent, :project), do: @agent.project.name, else: "—"}
        </:item>
        <:item title="Status">{@agent.status}</:item>
      </.list>

      <div class="space-y-4">
        <h3 class="font-semibold">Recent Sessions</h3>
        <div
          :if={Ash.Resource.loaded?(@agent, :sessions) && @agent.sessions != []}
          class="space-y-2"
        >
          <div
            :for={session <- @agent.sessions}
            class="card bg-base-200 p-3"
          >
            <div class="flex items-center justify-between text-sm">
              <span class={[
                "badge badge-sm",
                session.status == :running && "badge-info",
                session.status == :completed && "badge-success",
                session.status == :failed && "badge-error",
                session.status == :cancelled && "badge-ghost"
              ]}>
                {session.status}
              </span>
              <span class="text-xs text-base-content/50">
                {if session.started_at,
                  do: Calendar.strftime(session.started_at, "%Y-%m-%d %H:%M"),
                  else: "—"}
              </span>
            </div>
            <pre
              :if={session.output_log}
              class="mt-2 text-xs overflow-auto max-h-40 bg-base-300 p-2 rounded"
            >{session.output_log}</pre>
          </div>
        </div>
        <p
          :if={!Ash.Resource.loaded?(@agent, :sessions) || @agent.sessions == []}
          class="text-sm text-base-content/50"
        >
          No sessions yet
        </p>
      </div>
    </div>
    """
  end
end
