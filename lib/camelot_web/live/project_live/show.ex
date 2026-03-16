defmodule CamelotWeb.ProjectLive.Show do
  @moduledoc """
  LiveView for displaying project details.
  """
  use CamelotWeb, :live_view

  alias Camelot.Projects.Project
  alias Phoenix.LiveView.Socket

  @impl true
  @spec mount(map(), map(), Socket.t()) ::
          {:ok, Socket.t()}
  def mount(%{"id" => id}, _session, socket) do
    project = Ash.get!(Project, id)

    {:ok,
     assign(socket,
       page_title: project.name,
       project: project
     )}
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
      </.list>
    </div>
    """
  end
end
