defmodule CamelotWeb.Components.TaskPicker do
  @moduledoc """
  LiveComponent for searching and selecting another task — used to
  pick a task's parent, blockers, or related tasks from `BoardLive`'s
  create-task modal and `TaskLive`'s "Add link" modal.

  Reuses only `CamelotWeb.Components.FolderPicker`'s `mount/update/
  render` skeleton and its `send(self(), {:folder_selected, ...})`
  notify pattern — `FolderPicker`'s own text input has no `phx-change`
  wired, so the debounced `phx-change` search here is new.

  Results are scoped to the current user's project memberships via
  `CamelotWeb.Scope.scope_tasks/2`, bypassed only when the caller
  passes `see_all?: true` (an admin with the board's "Showing: All"
  toggle on) — mirroring `CamelotWeb.Scope.maybe_scope/4`.

  The search is a plain `ilike` sequential scan over `tasks.title`,
  bounded by a two-character minimum query, the membership scope and
  the ten-row limit. That is deliberate at the board sizes this
  app runs at (thousands of tasks); a `gin_trgm_ops` index on
  `tasks.title` is the escalation path if that stops holding.
  """
  use CamelotWeb, :live_component

  import CamelotWeb.BoardComponents, only: [state_badge: 1]

  alias Camelot.Board.Task
  alias CamelotWeb.Scope

  require Ash.Query

  @max_results 10

  @impl true
  def mount(socket) do
    {:ok, assign(socket, query: "", results: [])}
  end

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(exclude_ids: [], see_all?: false, placeholder: "Search tasks…")
      |> assign(assigns)

    {:ok, socket}
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    {:noreply, assign(socket, query: query, results: search(socket, query))}
  end

  def handle_event("select", %{"id" => id}, socket) do
    task = Enum.find(socket.assigns.results, &(&1.id == id))

    if task do
      send(self(), {:task_selected, socket.assigns.field, task})
    end

    {:noreply, assign(socket, query: "", results: [])}
  end

  def handle_event("clear", _params, socket) do
    send(self(), {:task_cleared, socket.assigns.field})
    {:noreply, assign(socket, query: "", results: [])}
  end

  defp search(_socket, query) when byte_size(query) < 2, do: []

  defp search(socket, query) do
    exclude_ids = socket.assigns.exclude_ids

    Task
    |> Ash.Query.filter(ilike(title, ^like_pattern(query)))
    |> Ash.Query.filter(id not in ^exclude_ids)
    |> Ash.Query.limit(@max_results)
    |> Scope.maybe_scope(socket.assigns.current_user, socket.assigns.see_all?, &Scope.scope_tasks/2)
    |> Ash.read!(load: [:project])
  end

  # `ilike` is the only case-insensitive match Ash offers here
  # (`contains/2` compiles to a case-sensitive `strpos`), so the
  # pattern is built up front with the LIKE metacharacters escaped:
  # a title typed as "50%_off" searches for that literal text instead
  # of turning into a wildcard. Ash still parameterises the resulting
  # string, this only stops it from being read as a pattern.
  @spec like_pattern(String.t()) :: String.t()
  defp like_pattern(query) do
    escaped = String.replace(query, ~r/([\\%_])/, "\\\\\\1")

    "%#{escaped}%"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="w-full">
      <div class="fieldset mb-2">
        <span :if={@label} class="label mb-1">{@label}</span>
        <div :if={@selected} class="flex items-center gap-2 p-2 rounded bg-base-200 text-sm">
          <span class="truncate">{@selected.title}</span>
          <button
            type="button"
            class="btn btn-ghost btn-xs ml-auto"
            phx-click="clear"
            phx-target={@myself}
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>
        <input
          :if={!@selected}
          type="search"
          name="query"
          value={@query}
          placeholder={@placeholder}
          class="w-full input"
          phx-change="search"
          phx-target={@myself}
          phx-debounce="300"
          autocomplete="off"
        />
      </div>

      <ul
        :if={!@selected && @results != []}
        class="border border-base-300 rounded-lg bg-base-200 max-h-56 overflow-y-auto space-y-0.5 p-1"
      >
        <li :for={task <- @results}>
          <button
            type="button"
            class="w-full text-left px-2 py-1 rounded hover:bg-base-300
                   text-sm flex items-center gap-2"
            phx-click="select"
            phx-value-id={task.id}
            phx-target={@myself}
          >
            <.state_badge :if={task.state} state={task.state} />
            <span class="truncate">{task.title}</span>
            <span
              :if={Ash.Resource.loaded?(task, :project) && task.project}
              class="text-xs text-base-content/50 ml-auto shrink-0"
            >
              {task.project.name}
            </span>
          </button>
        </li>
      </ul>

      <p
        :if={!@selected && @query != "" && byte_size(@query) >= 2 && @results == []}
        class="text-xs text-base-content/50 px-1"
      >
        No matching tasks
      </p>
    </div>
    """
  end
end
