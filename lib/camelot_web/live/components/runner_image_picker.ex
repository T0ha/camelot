defmodule CamelotWeb.Components.RunnerImagePicker do
  @moduledoc """
  LiveComponent suggesting the runner images Camelot itself
  builds (`Camelot.RunnerImages`), while leaving the backing
  text input freely editable so a fully custom image
  reference always remains valid.

  Modeled on `CamelotWeb.Components.FolderPicker`: only
  needs `name`/`value`/`label`/`id` assigns, and hands a
  selection back to its parent as a raw message
  (`{:runner_image_selected, image}`).
  """
  use CamelotWeb, :live_component

  alias Camelot.RunnerImages

  @impl true
  def mount(socket) do
    {:ok, assign(socket, browsing?: false, images: RunnerImages.list())}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def handle_event("toggle_browser", _params, socket) do
    {:noreply, assign(socket, browsing?: !socket.assigns.browsing?)}
  end

  def handle_event("select", %{"image" => image}, socket) do
    send(self(), {:runner_image_selected, image})
    {:noreply, assign(socket, browsing?: false)}
  end

  @impl true
  def render(assigns) do
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
              <.icon name="hero-cube" class="size-5" />
            </button>
          </div>
        </label>
      </div>

      <div
        :if={@browsing?}
        class="border border-base-300 rounded-lg bg-base-200 p-3 mt-1"
      >
        <ul class="max-h-48 overflow-y-auto space-y-0.5">
          <li :for={%{stack: stack, image: image} <- @images}>
            <button
              type="button"
              class="w-full text-left px-2 py-1 rounded
                     hover:bg-base-300 text-sm flex items-center
                     gap-1"
              phx-click="select"
              phx-value-image={image}
              phx-target={@myself}
            >
              <.icon name="hero-cube" class="size-4 text-secondary" />
              <span class="font-semibold">{stack}</span>
              <code class="text-xs opacity-70">{image}</code>
            </button>
          </li>
        </ul>
      </div>
    </div>
    """
  end
end
