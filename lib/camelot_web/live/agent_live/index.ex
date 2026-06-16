defmodule CamelotWeb.AgentLive.Index do
  @moduledoc """
  LiveView listing all agents with status indicators.
  """
  use CamelotWeb, :live_view

  alias Camelot.Agents.Agent
  alias Camelot.Agents.AgentTemplate
  alias Camelot.Projects.Project
  alias CamelotWeb.Scope

  require Ash.Query

  @impl true
  def mount(params, _session, socket) do
    socket = assign(socket, see_all: params["scope"] == "all")

    if connected?(socket) do
      for agent <- scoped_agents(socket) do
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
          projects = scoped_projects(socket)
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
                "project_id" => "",
                "max_retries" => "3"
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

  @agent_fields ~w(name template_id project_id max_retries)

  @impl true
  def handle_event("save", params, socket) do
    agent_params =
      params
      |> Map.take(@agent_fields)
      |> normalise_max_retries()
      |> Map.put("user_id", socket.assigns.current_user.id)

    case Ash.create(Agent, agent_params, actor: socket.assigns.current_user) do
      {:ok, _agent} ->
        {:noreply,
         socket
         |> put_flash(:info, "Agent created")
         |> push_navigate(to: ~p"/agents")}

      {:error, error} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Failed to create agent: #{format_error(error)}"
         )}
    end
  end

  def handle_event("toggle_scope", _params, socket) do
    {:noreply, socket |> assign(see_all: !socket.assigns.see_all) |> load_agents()}
  end

  defp normalise_max_retries(%{"max_retries" => v} = p) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} when n >= 0 -> %{p | "max_retries" => n}
      _ -> Map.delete(p, "max_retries")
    end
  end

  defp normalise_max_retries(p), do: p

  defp format_error(%Ash.Error.Invalid{errors: errors}) when is_list(errors) do
    Enum.map_join(errors, "; ", fn
      %{field: f, message: m} when not is_nil(f) -> "#{f}: #{m}"
      %{message: m} when is_binary(m) -> m
      other -> inspect(other)
    end)
  end

  defp format_error(other), do: inspect(other)

  defp load_agents(socket) do
    assign(socket, agents: scoped_agents(socket, load: [:project, :template]))
  end

  defp scoped_agents(socket, opts \\ []) do
    Agent
    |> Scope.maybe_scope(
      socket.assigns.current_user,
      socket.assigns.see_all,
      &Scope.scope_agents/2
    )
    |> Ash.read!(opts)
  end

  defp scoped_projects(socket) do
    Project
    |> Scope.maybe_scope(
      socket.assigns.current_user,
      socket.assigns.see_all,
      &Scope.scope_projects/2
    )
    |> Ash.read!()
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
        <div class="flex items-center gap-2">
          <button
            :if={@current_user.role == :admin}
            phx-click="toggle_scope"
            class="btn btn-ghost btn-sm"
          >
            Showing: <span class="font-bold">{if @see_all, do: "All", else: "Mine"}</span>
          </button>
          <.link
            navigate={~p"/agents/new"}
            class="btn btn-primary"
          >
            New Agent
          </.link>
        </div>
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
            <.input
              field={@form[:max_retries]}
              type="number"
              min="0"
              label="Max retries"
            />
            <p class="text-xs text-base-content/50 -mt-2">
              How many times to re-dispatch after a failed run.
              0 disables retries.
            </p>
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
