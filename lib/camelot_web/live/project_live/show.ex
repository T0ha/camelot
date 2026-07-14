defmodule CamelotWeb.ProjectLive.Show do
  @moduledoc """
  LiveView for displaying project details.
  """
  use CamelotWeb, :live_view

  alias Camelot.Accounts.User
  alias Camelot.Projects.Project
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
           project: project
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
        <:item :if={@project.runner_image_override} title="Runner Image Override">
          <code>{@project.runner_image_override}</code>
        </:item>
      </.list>

      <.live_component
        module={EnvVarEditor}
        id="project-env-vars"
        scope={{:project, @project.id}}
      />
    </div>
    """
  end
end
