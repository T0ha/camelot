defmodule CamelotWeb.ProfileLive.Index do
  @moduledoc """
  Landing route for the old single-page `/profile`. The profile is
  split into one screen per section, so bookmarks and stale links
  are forwarded to the first of them.
  """
  use CamelotWeb, :live_view

  alias Phoenix.LiveView.Socket

  @impl true
  @spec mount(map(), map(), Socket.t()) :: {:ok, Socket.t()}
  def mount(_params, _session, socket) do
    {:ok, push_navigate(socket, to: ~p"/profile/ssh-key")}
  end

  @impl true
  def render(assigns), do: ~H""
end
