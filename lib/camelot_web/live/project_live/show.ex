defmodule CamelotWeb.ProjectLive.Show do
  @moduledoc """
  LiveView for displaying project details.
  """
  use CamelotWeb, :live_view

  alias Camelot.Accounts.User
  alias Camelot.Projects.Project
  alias Camelot.Runtime.Runner.DockerApi
  alias CamelotWeb.Components.EnvVarEditor
  alias CamelotWeb.Scope
  alias Phoenix.LiveView.Socket

  require Ash.Query

  @impl true
  @spec mount(map(), map(), Socket.t()) ::
          {:ok, Socket.t()} | {:halt, Socket.t()}
  def mount(%{"id" => id}, _session, socket) do
    case load_or_forbid(id, socket.assigns.current_user) do
      {:ok, project} ->
        {:ok,
         assign(socket,
           page_title: project.name,
           project: project,
           node_labels: node_labels(socket.assigns.current_user)
         )}

      :forbidden ->
        {:ok,
         socket
         |> put_flash(:error, "Project not found")
         |> push_navigate(to: ~p"/projects")}
    end
  end

  defp load_or_forbid(id, %User{role: :admin}), do: {:ok, Ash.get!(Project, id)}

  defp load_or_forbid(id, %User{} = user) do
    case Project
         |> Ash.Query.filter(id == ^id)
         |> Scope.scope_projects(user)
         |> Ash.read_one() do
      {:ok, %Project{} = project} -> {:ok, project}
      _ -> :forbidden
    end
  end

  @impl true
  def handle_event(
        "set_node_label",
        %{"swarm_node_label" => label},
        %Socket{assigns: %{current_user: %User{role: :admin} = actor}} = socket
      ) do
    socket.assigns.project
    |> Ash.Changeset.for_update(:set_swarm_node_label, %{swarm_node_label: blank_to_nil(label)}, actor: actor)
    |> Ash.update()
    |> case do
      {:ok, updated} ->
        {:noreply, assign(socket, project: updated)}

      {:error, _error} ->
        {:noreply, put_flash(socket, :error, "Could not save the node pin.")}
    end
  end

  def handle_event("set_node_label", _params, socket), do: {:noreply, socket}

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp node_labels(%User{role: :admin}), do: DockerApi.list_node_labels_or_empty()
  defp node_labels(%User{}), do: []

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <div>
          <.link
            navigate={~p"/projects"}
            class="text-sm text-base-content/60"
          >
            &larr; Back to projects
          </.link>
          <h1 class="text-2xl font-bold">
            {@project.name}
          </h1>
        </div>
        <div class="flex gap-2">
          <.link
            navigate={~p"/projects/#{@project.id}/edit"}
            class="btn btn-sm btn-outline"
          >
            Edit
          </.link>
        </div>
      </div>

      <.list>
        <:item title="Status">
          <span class={[
            "badge",
            @project.status == :active && "badge-success",
            @project.status == :archived && "badge-ghost"
          ]}>
            {@project.status}
          </span>
        </:item>
        <:item title="Path">
          <code>{@project.path}</code>
        </:item>
        <:item :if={@project.description} title="Description">
          {@project.description}
        </:item>
        <:item :if={@project.github_repo_url} title="GitHub">
          {@project.github_repo_url}
        </:item>
      </.list>

      <div :if={@current_user.role == :admin} class="rounded border p-4 space-y-2">
        <h2 class="text-lg font-semibold">Swarm node pin</h2>

        <p class="text-sm text-base-content/60">
          Pins this project's runners to a Swarm node label. Overrides the
          owner's personal pin and the instance-wide default. Leave blank
          to fall back to them.
        </p>

        <form id="project-node-label-form" phx-change="set_node_label">
          <.node_label_pin
            name="swarm_node_label"
            value={@project.swarm_node_label}
            node_labels={@node_labels}
            placeholder="e.g. gpu-1"
          />
        </form>
      </div>

      <.live_component
        module={EnvVarEditor}
        id="project-env-vars"
        scope={{:project, @project.id}}
      />
    </div>
    """
  end
end
