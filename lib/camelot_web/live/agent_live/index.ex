defmodule CamelotWeb.AgentLive.Index do
  @moduledoc """
  LiveView listing all agents with status indicators.
  """
  use CamelotWeb, :live_view

  alias Camelot.Agents.Agent
  alias Camelot.Agents.AgentTemplate
  alias Camelot.Projects.Project

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
  def handle_params(_params, _url, socket) do
    socket =
      case socket.assigns.live_action do
        :new ->
          projects = Ash.read!(Project)
          templates = load_templates()
          default_template_id = default_template_id(templates)

          assign(socket,
            page_title: "New Agent",
            projects: projects,
            templates: templates,
            form:
              to_form(%{
                "name" => "",
                "template_id" => default_template_id,
                "project_id" => ""
              })
          )

        _ ->
          assign(socket, page_title: "Agents")
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:agent_updated, _agent}, socket) do
    {:noreply, load_agents(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @agent_fields ~w(name template_id project_id)

  @impl true
  def handle_event("save", params, socket) do
    agent_params = Map.take(params, @agent_fields)

    case Ash.create(Agent, agent_params) do
      {:ok, _agent} ->
        {:noreply,
         socket
         |> put_flash(:info, "Agent created")
         |> push_navigate(to: ~p"/agents")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to create agent")}
    end
  end

  defp load_agents(socket) do
    agents = Ash.read!(Agent, load: [:project, :template])

    assign(socket, agents: agents)
  end

  defp load_templates do
    AgentTemplate
    |> Ash.read!()
    |> Enum.sort_by(& &1.slug)
  end

  defp default_template_id([]), do: ""
  defp default_template_id([t | _]), do: t.id

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-bold">Agents</h1>
        <.link
          navigate={~p"/agents/new"}
          class="btn btn-primary"
        >
          New Agent
        </.link>
      </div>

      <%= if @live_action == :new do %>
        <.modal
          id="agent-modal"
          show
          on_cancel={JS.navigate(~p"/agents")}
        >
          <.header>New Agent</.header>

          <.simple_form
            for={@form}
            id="agent-form"
            phx-submit="save"
          >
            <.input
              field={@form[:name]}
              type="text"
              label="Name"
            />
            <.input
              field={@form[:template_id]}
              type="select"
              label="Template"
              options={Enum.map(@templates, &{&1.name, &1.id})}
            />
            <.input
              field={@form[:project_id]}
              type="select"
              label="Project"
              prompt="Select project"
              options={Enum.map(@projects, &{&1.name, &1.id})}
            />
            <:actions>
              <.button
                phx-disable-with="Creating..."
                class="btn btn-primary"
              >
                Create Agent
              </.button>
            </:actions>
          </.simple_form>
        </.modal>
      <% end %>

      <div
        :if={@agents == []}
        class="text-center py-12 text-base-content/50"
      >
        No agents configured yet.
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
            <p
              :if={Ash.Resource.loaded?(agent, :template)}
              class="text-sm text-base-content/60"
            >
              {agent.template.name}
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
