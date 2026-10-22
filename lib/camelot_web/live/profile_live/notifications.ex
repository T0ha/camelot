defmodule CamelotWeb.ProfileLive.Notifications do
  @moduledoc """
  Profile screen for the per-user email notification preferences.
  """
  use CamelotWeb, :live_view

  alias Phoenix.LiveView.Socket

  @pref_keys [
    "notify_on_waiting_for_input",
    "notify_on_error",
    "notify_on_done",
    "notify_on_usage_limit_paused",
    "notify_on_usage_limit_resumed"
  ]

  @impl true
  @spec mount(map(), map(), Socket.t()) :: {:ok, Socket.t()}
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Email notifications")
     |> assign_form()}
  end

  @impl true
  def handle_event("update_notification_prefs", %{"prefs" => params}, socket) do
    user = socket.assigns.current_user

    case Ash.update(user, Map.take(params, @pref_keys),
           action: :update_notification_preferences,
           actor: user
         ) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(:current_user, user)
         |> put_flash(:info, "Preferences saved")
         |> assign_form()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to save preferences")}
    end
  end

  # Never crash the screen on an unexpected message.
  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp assign_form(socket) do
    user = socket.assigns.current_user

    form =
      to_form(
        %{
          "notify_on_waiting_for_input" => user.notify_on_waiting_for_input,
          "notify_on_error" => user.notify_on_error,
          "notify_on_done" => user.notify_on_done,
          "notify_on_usage_limit_paused" => user.notify_on_usage_limit_paused,
          "notify_on_usage_limit_resumed" => user.notify_on_usage_limit_resumed
        },
        as: "prefs"
      )

    assign(socket, :notification_prefs_form, form)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <h1 class="text-2xl font-bold">Email notifications</h1>

      <section class="rounded border p-4 space-y-3">
        <p class="text-sm text-base-content/60">
          Get notified by email when one of your task cards needs
          attention.
        </p>

        <.simple_form
          for={@notification_prefs_form}
          phx-submit="update_notification_prefs"
          id="notification-prefs-form"
        >
          <.input
            field={@notification_prefs_form[:notify_on_waiting_for_input]}
            type="checkbox"
            label="Email me when a task needs input"
          />
          <.input
            field={@notification_prefs_form[:notify_on_error]}
            type="checkbox"
            label="Email me when a task errors"
          />
          <.input
            field={@notification_prefs_form[:notify_on_done]}
            type="checkbox"
            label="Email me when a task is done"
          />
          <.input
            field={@notification_prefs_form[:notify_on_usage_limit_paused]}
            type="checkbox"
            label="Email me when a provider usage limit pauses my tasks"
          />
          <.input
            field={@notification_prefs_form[:notify_on_usage_limit_resumed]}
            type="checkbox"
            label="Email me when my paused tasks resume"
          />
          <:actions>
            <.button>Save preferences</.button>
          </:actions>
        </.simple_form>
      </section>
    </div>
    """
  end
end
