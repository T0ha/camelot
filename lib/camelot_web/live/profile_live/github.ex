defmodule CamelotWeb.ProfileLive.Github do
  @moduledoc """
  Profile screen for the user's GitHub App installations: connect a
  new organization or disconnect an existing one.
  """
  use CamelotWeb, :live_view

  alias Camelot.Github.AppConfig
  alias Camelot.Github.Installation
  alias Camelot.Telemetry.Capture
  alias CamelotWeb.GithubSetupController
  alias Phoenix.LiveView.Socket

  @impl true
  @spec mount(map(), map(), Socket.t()) :: {:ok, Socket.t()}
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "GitHub")
     |> load_state()}
  end

  # The connect button is a plain link out to GitHub, so this is the
  # only point at which the app sees the attempt at all: without it a
  # user who abandons GitHub's install screen is indistinguishable
  # from one who never clicked. The `href` navigation is unaffected.
  @impl true
  def handle_event("github_setup_started", _params, socket) do
    Capture.capture("github_setup_started", socket.assigns.current_user, %{})

    {:noreply, socket}
  end

  def handle_event("disconnect_github_app", %{"id" => id}, socket) do
    user = socket.assigns.current_user
    installation = Ash.get!(Installation, id, actor: user)
    Ash.destroy!(installation, actor: user)

    {:noreply,
     socket
     |> put_flash(:info, "GitHub App disconnected.")
     |> load_state()}
  end

  # Never crash the screen on an unexpected message.
  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp load_state(socket) do
    user =
      Ash.load!(socket.assigns.current_user, :github_installations, actor: socket.assigns.current_user)

    socket
    |> assign(
      current_user: user,
      github_installations_count: length(user.github_installations),
      github_app_configured?: AppConfig.configured?(),
      github_connect_url: github_connect_url(user)
    )
    |> stream(:github_installations, user.github_installations, reset: true)
  end

  defp github_connect_url(user) do
    AppConfig.install_url(GithubSetupController.state_token(user.id))
  end

  defp connect_label(0), do: "Connect GitHub App"
  defp connect_label(_count), do: "Connect another organization"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <h1 class="text-2xl font-bold">GitHub</h1>

      <section id="github-app" class="rounded border p-4 space-y-2">
        <h2 class="text-lg font-semibold">GitHub App</h2>

        <p class="text-sm text-base-content/60">
          Linking a GitHub App installation lets Camelot poll PR/issue
          status and lets runners push over HTTPS without an SSH key
          or pasted token, using your credentials for tasks you create.
        </p>

        <p :if={!@github_app_configured?} class="text-sm text-warning">
          No GitHub App is configured for this deployment.
        </p>

        <ul
          :if={@github_app_configured?}
          id="github-installations"
          phx-update="stream"
          class="text-sm space-y-2"
        >
          <li
            :for={{dom_id, installation} <- @streams.github_installations}
            id={dom_id}
            class="flex items-center justify-between gap-2"
          >
            <p>
              Connected to <strong>{installation.account_login}</strong>
              <span class="badge badge-ghost">{installation.account_type}</span>
              <span :if={installation.suspended_at} class="badge badge-warning">
                suspended
              </span>
            </p>
            <button
              class="btn btn-sm btn-outline"
              phx-click="disconnect_github_app"
              phx-value-id={installation.id}
              data-confirm="Disconnect the GitHub App?"
            >
              Disconnect
            </button>
          </li>
        </ul>

        <a
          :if={@github_app_configured? && @github_connect_url}
          href={@github_connect_url}
          phx-click="github_setup_started"
          class="btn btn-sm btn-primary"
        >
          {connect_label(@github_installations_count)}
        </a>
      </section>
    </div>
    """
  end
end
