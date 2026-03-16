defmodule CamelotWeb.ProjectLive.Index do
  @moduledoc """
  LiveView for listing and managing projects.
  """
  use CamelotWeb, :live_view

  alias Camelot.Projects.Project
  alias Phoenix.LiveView.Socket

  @impl true
  @spec mount(map(), map(), Socket.t()) ::
          {:ok, Socket.t()}
  def mount(_params, _session, socket) do
    {:ok, load_projects(socket)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    assign(socket,
      page_title: "Projects",
      project: nil
    )
  end

  defp apply_action(socket, :new, _params) do
    assign(socket,
      page_title: "New Project",
      project: nil,
      form: to_form(project_create_params())
    )
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    project = Ash.get!(Project, id)

    assign(socket,
      page_title: "Edit Project",
      project: project,
      form: to_form(project_update_params(project))
    )
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    project = Ash.get!(Project, id)
    Ash.destroy!(project)

    {:noreply,
     socket
     |> put_flash(:info, "Project deleted")
     |> load_projects()}
  end

  def handle_event("save", %{"project" => params}, socket) do
    save_project(socket, socket.assigns.live_action, params)
  end

  defp save_project(socket, :new, params) do
    case Ash.create(Project, params, action: :create) do
      {:ok, _project} ->
        {:noreply,
         socket
         |> put_flash(:info, "Project created")
         |> push_navigate(to: ~p"/projects")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset_params(changeset)))}
    end
  end

  defp save_project(socket, :edit, params) do
    case Ash.update(socket.assigns.project, params, action: :update) do
      {:ok, _project} ->
        {:noreply,
         socket
         |> put_flash(:info, "Project updated")
         |> push_navigate(to: ~p"/projects")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset_params(changeset)))}
    end
  end

  defp load_projects(socket) do
    projects = Ash.read!(Project)
    assign(socket, projects: projects)
  end

  defp project_create_params do
    %{
      "name" => "",
      "path" => "",
      "description" => "",
      "github_repo_url" => "",
      "github_owner" => "",
      "github_repo" => ""
    }
  end

  defp project_update_params(project) do
    %{
      "name" => project.name || "",
      "description" => project.description || "",
      "github_repo_url" => project.github_repo_url || "",
      "github_owner" => project.github_owner || "",
      "github_repo" => project.github_repo || "",
      "status" => to_string(project.status)
    }
  end

  defp changeset_params(changeset) do
    Map.get(changeset, :params, %{})
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-bold">Projects</h1>
        <.link
          navigate={~p"/projects/new"}
          class="btn btn-primary"
        >
          New Project
        </.link>
      </div>

      <%= if @live_action in [:new, :edit] do %>
        <.modal
          id="project-modal"
          show
          on_cancel={JS.navigate(~p"/projects")}
        >
          <.header>
            {@page_title}
          </.header>

          <.simple_form
            for={@form}
            id="project-form"
            phx-submit="save"
          >
            <.input
              field={@form[:name]}
              type="text"
              label="Name"
            />
            <%= if @live_action == :new do %>
              <.input
                field={@form[:path]}
                type="text"
                label="Path"
              />
            <% end %>
            <.input
              field={@form[:description]}
              type="textarea"
              label="Description"
            />
            <.input
              field={@form[:github_repo_url]}
              type="text"
              label="GitHub URL"
            />
            <.input
              field={@form[:github_owner]}
              type="text"
              label="GitHub Owner"
            />
            <.input
              field={@form[:github_repo]}
              type="text"
              label="GitHub Repo"
            />
            <%= if @live_action == :edit do %>
              <.input
                field={@form[:status]}
                type="select"
                label="Status"
                options={[
                  {"Active", "active"},
                  {"Archived", "archived"}
                ]}
              />
            <% end %>
            <:actions>
              <.button
                phx-disable-with="Saving..."
                class="btn btn-primary"
              >
                Save
              </.button>
            </:actions>
          </.simple_form>
        </.modal>
      <% end %>

      <div class="overflow-x-auto">
        <.table
          id="projects"
          rows={@projects}
          row_click={
            fn project ->
              JS.navigate(~p"/projects/#{project.id}")
            end
          }
        >
          <:col :let={project} label="Name">
            {project.name}
          </:col>
          <:col :let={project} label="Path">
            <code class="text-xs">{project.path}</code>
          </:col>
          <:col :let={project} label="Status">
            <span class={[
              "badge",
              project.status == :active && "badge-success",
              project.status == :archived && "badge-ghost"
            ]}>
              {project.status}
            </span>
          </:col>
          <:action :let={project}>
            <.link navigate={~p"/projects/#{project.id}/edit"}>
              Edit
            </.link>
          </:action>
          <:action :let={project}>
            <.link
              phx-click={JS.push("delete", value: %{id: project.id})}
              data-confirm="Are you sure?"
            >
              Delete
            </.link>
          </:action>
        </.table>
      </div>
    </div>
    """
  end
end
