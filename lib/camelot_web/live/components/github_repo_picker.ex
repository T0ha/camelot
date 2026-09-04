defmodule CamelotWeb.Components.GithubRepoPicker do
  @moduledoc """
  LiveComponent for browsing and selecting a GitHub
  repository from among those accessible via the current
  user's connected GitHub App installations.

  Modeled on `CamelotWeb.Components.FolderPicker`: it only
  needs `name`/`value`/`label`/`id`/`current_user` assigns,
  re-fetches on every `toggle_browser`, and hands the
  selection back to its parent as a raw message
  (`{:github_repo_selected, repo}`) rather than
  pubsub/notify_parent.
  """
  use CamelotWeb, :live_component

  alias Camelot.Github.RepositoryCatalog

  @impl true
  def mount(socket) do
    {:ok, assign(socket, browsing?: false, repos: [], filter: "")}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def handle_event("toggle_browser", _params, socket) do
    socket =
      if socket.assigns.browsing? do
        assign(socket, browsing?: false)
      else
        load_repos(socket)
      end

    {:noreply, socket}
  end

  def handle_event("filter", %{"value" => text}, socket) do
    {:noreply, assign(socket, filter: text)}
  end

  def handle_event("select", %{"full_name" => full_name}, socket) do
    repo = Enum.find(socket.assigns.repos, &(&1.full_name == full_name))

    if repo do
      send(self(), {:github_repo_selected, repo})
    end

    {:noreply, assign(socket, browsing?: false)}
  end

  defp load_repos(socket) do
    case RepositoryCatalog.list_for_user(socket.assigns.current_user) do
      {:ok, repos} -> assign(socket, browsing?: true, repos: repos, filter: "")
      {:error, _reason} -> assign(socket, browsing?: true, repos: [], filter: "")
    end
  end

  defp filtered_repos(repos, ""), do: repos

  defp filtered_repos(repos, filter) do
    downcased = String.downcase(filter)
    Enum.filter(repos, &String.contains?(String.downcase(&1.full_name), downcased))
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :visible_repos, filtered_repos(assigns.repos, assigns.filter))

    ~H"""
    <div id={"#{@id}-container"} class="w-full">
      <div class="fieldset mb-2">
        <label>
          <span class="label mb-1">{@label}</span>
          <div class="flex gap-2">
            <input
              type="text"
              name={@name}
              id={@id}
              value={@value}
              class="w-full input"
              phx-debounce="300"
            />
            <button
              type="button"
              class="btn btn-ghost btn-sm"
              phx-click="toggle_browser"
              phx-target={@myself}
            >
              <.icon name="hero-magnifying-glass" class="size-5" />
            </button>
          </div>
        </label>
      </div>

      <div
        :if={@browsing?}
        class="border border-base-300 rounded-lg bg-base-200 p-3 mt-1"
      >
        <input
          type="text"
          value={@filter}
          placeholder="Filter repositories…"
          class="w-full input input-sm mb-2"
          phx-keyup="filter"
          phx-debounce="300"
          phx-target={@myself}
        />

        <ul class="max-h-48 overflow-y-auto space-y-0.5">
          <li :for={repo <- @visible_repos}>
            <button
              type="button"
              class="w-full text-left px-2 py-1 rounded
                     hover:bg-base-300 text-sm flex items-center
                     gap-1"
              phx-click="select"
              phx-value-full_name={repo.full_name}
              phx-target={@myself}
            >
              <.icon name="hero-code-bracket" class="size-4 text-info" />
              {repo.full_name}
            </button>
          </li>
          <li :if={@visible_repos == []}>
            <span class="text-sm opacity-50 px-2 py-1">
              No repositories found. Make sure the GitHub App
              is installed on the owner/org you're looking for.
            </span>
          </li>
        </ul>
      </div>
    </div>
    """
  end
end
