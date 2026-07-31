defmodule CamelotWeb.LiveUserAuth do
  @moduledoc """
  LiveView on_mount hooks for authentication.
  """
  use CamelotWeb, :verified_routes

  import Phoenix.Component
  import Phoenix.LiveView

  alias Phoenix.LiveView.Socket

  @spec on_mount(atom(), map(), map(), Socket.t()) ::
          {:cont | :halt, Socket.t()}
  def on_mount(:live_user_required, _params, _session, socket) do
    socket = attach_posthog_hook(socket)

    if socket.assigns[:current_user] do
      {:cont, socket}
    else
      {:halt,
       socket
       |> put_flash(:error, "You must sign in first")
       |> redirect(to: ~p"/sign-in")}
    end
  end

  def on_mount(:live_user_optional, _params, _session, socket) do
    {:cont, socket |> attach_posthog_hook() |> assign_new(:current_user, fn -> nil end)}
  end

  def on_mount(:live_admin_required, _params, _session, socket) do
    socket = attach_posthog_hook(socket)

    case socket.assigns[:current_user] do
      %{role: :admin} ->
        {:cont, socket}

      %{} ->
        {:halt,
         socket
         |> put_flash(:error, "You don't have access to this area.")
         |> redirect(to: ~p"/")}

      _ ->
        {:halt,
         socket
         |> put_flash(:error, "You must sign in first")
         |> redirect(to: ~p"/sign-in")}
    end
  end

  @doc """
  Keeps the process's PostHog `$current_url` context in sync with
  LiveView navigation, since a connected LiveView runs in a process
  separate from the HTTP request that rendered it.
  """
  @spec attach_posthog_hook(Socket.t()) :: Socket.t()
  def attach_posthog_hook(socket) do
    attach_hook(socket, :posthog_current_url, :handle_params, &set_posthog_current_url/3)
  end

  defp set_posthog_current_url(_params, uri, socket) do
    PostHog.set_context(%{"$current_url": uri})
    {:cont, socket}
  end
end
