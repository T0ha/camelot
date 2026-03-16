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
    {:cont, assign_new(socket, :current_user, fn -> nil end)}
  end
end
