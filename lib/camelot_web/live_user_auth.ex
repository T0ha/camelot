defmodule CamelotWeb.LiveUserAuth do
  @moduledoc """
  LiveView on_mount hooks for authentication.
  """
  use CamelotWeb, :verified_routes

  import Phoenix.Component
  import Phoenix.LiveView

  alias Camelot.Telemetry.Context
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
    put_logger_metadata(socket.assigns[:current_user])

    attach_hook(socket, :posthog_current_url, :handle_params, &set_posthog_current_url/3)
  end

  defp set_posthog_current_url(_params, uri, socket) do
    PostHog.set_context(%{"$current_url": uri})
    {:cont, socket}
  end

  # Every `Logger` call from this LiveView process inherits these, so
  # the JSON log pipeline can filter a user's whole session without
  # the id having to be interpolated into each message — and a crash
  # in this LiveView is reported to error tracking as this person's
  # rather than as `"unknown"`.
  defp put_logger_metadata(%{id: id}), do: Context.put_person_metadata(id)
  defp put_logger_metadata(_anonymous), do: :ok
end
