defmodule CamelotWeb.AdminLive.Settings do
  @moduledoc """
  Admin-only view for instance-wide settings. Mounted via
  `:live_admin_required` which gates access to admins.
  """
  use CamelotWeb, :live_view

  alias Camelot.Settings
  alias Camelot.Settings.SystemSetting
  alias Phoenix.LiveView.Socket

  @impl true
  @spec mount(map(), map(), Socket.t()) :: {:ok, Socket.t()}
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Settings",
       default_swarm_node_label: Settings.default_swarm_node_label()
     )}
  end

  @impl true
  def handle_event("set_default_node_label", %{"default_swarm_node_label" => label}, socket) do
    actor = socket.assigns.current_user

    SystemSetting
    |> Ash.Changeset.for_create(
      :set_default_swarm_node_label,
      %{default_swarm_node_label: blank_to_nil(label)},
      actor: actor
    )
    |> Ash.create()
    |> case do
      {:ok, setting} ->
        {:noreply,
         socket
         |> put_flash(:info, "Saved.")
         |> assign(default_swarm_node_label: setting.default_swarm_node_label)}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, format_error(error))}
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp format_error(%Ash.Error.Invalid{errors: [%{message: msg} | _]}) when is_binary(msg), do: msg

  defp format_error(_), do: "Could not save changes."

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <h1 class="text-2xl font-bold">Settings</h1>

      <section class="rounded border p-4 space-y-3">
        <h2 class="text-lg font-semibold">Default swarm node pin</h2>

        <p class="text-sm text-base-content/60">
          Instance-wide fallback used when neither a project nor its
          owner has a swarm node pin set.
        </p>

        <form id="system-settings-form" phx-change="set_default_node_label">
          <input
            type="text"
            name="default_swarm_node_label"
            value={@default_swarm_node_label}
            placeholder="e.g. gpu-1"
            class="input input-bordered input-sm"
          />
        </form>
      </section>
    </div>
    """
  end
end
