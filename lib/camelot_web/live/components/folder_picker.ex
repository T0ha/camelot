defmodule CamelotWeb.Components.FolderPicker do
  @moduledoc """
  LiveComponent for browsing and selecting local folders.
  """
  use CamelotWeb, :live_component

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       browsing?: false,
       current_dir: default_projects_dir(),
       entries: []
     )}
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
        dir = socket.assigns.current_dir

        socket
        |> assign(browsing?: true)
        |> load_entries(dir)
      end

    {:noreply, socket}
  end

  def handle_event("navigate", %{"path" => path}, socket) do
    {:noreply, load_entries(socket, path)}
  end

  def handle_event("select", _params, socket) do
    send(self(), {:folder_selected, socket.assigns.current_dir})
    {:noreply, assign(socket, browsing?: false)}
  end

  defp load_entries(socket, dir) do
    expanded = Path.expand(dir)

    case File.ls(expanded) do
      {:ok, files} ->
        dirs =
          files
          |> Enum.filter(fn name ->
            not String.starts_with?(name, ".") and
              File.dir?(Path.join(expanded, name))
          end)
          |> Enum.sort()

        assign(socket,
          current_dir: expanded,
          entries: dirs
        )

      {:error, _reason} ->
        assign(socket,
          current_dir: expanded,
          entries: []
        )
    end
  end

  defp breadcrumbs(path) do
    parts = Path.split(path)

    parts
    |> Enum.reduce([], fn part, acc ->
      full =
        case acc do
          [] -> part
          [{_label, prev} | _] -> Path.join(prev, part)
        end

      [{part, full} | acc]
    end)
    |> Enum.reverse()
  end

  defp default_projects_dir do
    :camelot
    |> Application.get_env(:default_projects_dir, "~/projects")
    |> Path.expand()
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :breadcrumbs, breadcrumbs(assigns.current_dir))

    ~H"""
    <div class="w-full">
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
              <.icon name="hero-folder-open" class="size-5" />
            </button>
          </div>
        </label>
      </div>

      <div
        :if={@browsing?}
        class="border border-base-300 rounded-lg bg-base-200 p-3 mt-1"
      >
        <div class="flex flex-wrap items-center gap-1 text-sm mb-2">
          <span
            :for={{label, path} <- @breadcrumbs}
            class="inline-flex items-center"
          >
            <button
              type="button"
              class="link link-hover text-xs"
              phx-click="navigate"
              phx-value-path={path}
              phx-target={@myself}
            >
              {label}
            </button>
            <span class="mx-0.5 opacity-50">/</span>
          </span>
        </div>

        <ul class="max-h-48 overflow-y-auto space-y-0.5">
          <li :if={Path.dirname(@current_dir) != @current_dir}>
            <button
              type="button"
              class="w-full text-left px-2 py-1 rounded
                     hover:bg-base-300 text-sm flex items-center
                     gap-1"
              phx-click="navigate"
              phx-value-path={Path.dirname(@current_dir)}
              phx-target={@myself}
            >
              <.icon name="hero-arrow-up" class="size-4 opacity-50" /> ..
            </button>
          </li>
          <li :for={entry <- @entries}>
            <button
              type="button"
              class="w-full text-left px-2 py-1 rounded
                     hover:bg-base-300 text-sm flex items-center
                     gap-1"
              phx-click="navigate"
              phx-value-path={Path.join(@current_dir, entry)}
              phx-target={@myself}
            >
              <.icon name="hero-folder" class="size-4 text-warning" />
              {entry}
            </button>
          </li>
          <li :if={@entries == []}>
            <span class="text-sm opacity-50 px-2 py-1">
              No subdirectories
            </span>
          </li>
        </ul>

        <div class="flex justify-end mt-2 pt-2 border-t border-base-300">
          <button
            type="button"
            class="btn btn-primary btn-sm"
            phx-click="select"
            phx-target={@myself}
          >
            Select this folder
          </button>
        </div>
      </div>
    </div>
    """
  end
end
