defmodule CamelotWeb.ProfileLive.Capacity do
  @moduledoc """
  Profile screen showing the runner pool's capacity for the current
  user and the cluster, plus the user's recent bootstrap runs.
  """
  use CamelotWeb, :live_view

  alias Camelot.Agents.Session
  alias Camelot.Runtime.RunnerPool
  alias Phoenix.LiveView.Socket

  require Ash.Query

  @impl true
  @spec mount(map(), map(), Socket.t()) :: {:ok, Socket.t()}
  def mount(_params, _session, socket) do
    subscribe_to_pool(connected?(socket))

    user = socket.assigns.current_user

    {:ok,
     assign(socket,
       page_title: "Running capacity",
       pool: pool_for(user),
       bootstrap_history: bootstrap_history(user)
     )}
  end

  @impl true
  def handle_info(:pool_changed, socket) do
    {:noreply, assign(socket, :pool, pool_for(socket.assigns.current_user))}
  end

  # Never crash the screen on an unexpected PubSub message.
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp subscribe_to_pool(true) do
    Phoenix.PubSub.subscribe(Camelot.PubSub, "runner_pool")
  end

  defp subscribe_to_pool(false), do: :ok

  defp bootstrap_history(user) do
    Session
    |> Ash.Query.filter(user_id == ^user.id and kind == :bootstrap)
    |> Ash.Query.sort(queued_at: :desc)
    |> Ash.Query.limit(10)
    |> Ash.read!()
  end

  defp pool_for(user) do
    snap = safe_snapshot()

    per_user =
      Map.get(snap.per_user, user.id, %{
        active: 0,
        max: snap.global.max,
        queued: 0
      })

    %{global: snap.global, user: per_user}
  end

  defp safe_snapshot do
    RunnerPool.snapshot()
  catch
    :exit, _ -> %{global: %{active: 0, max: 0}, per_user: %{}}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <h1 class="text-2xl font-bold">Running capacity</h1>

      <section class="rounded border p-4 space-y-2">
        <div class="grid grid-cols-3 gap-4 text-sm">
          <div>
            <div class="text-base-content/60">You — running</div>
            <div class="text-2xl">{@pool.user.active}/{@pool.user.max}</div>
          </div>
          <div>
            <div class="text-base-content/60">You — queued</div>
            <div class="text-2xl">{@pool.user.queued}</div>
          </div>
          <div>
            <div class="text-base-content/60">Cluster — running</div>
            <div class="text-2xl">{@pool.global.active}/{@pool.global.max}</div>
          </div>
        </div>

        <p :if={@pool.user.queued > 0} class="text-sm text-base-content/60">
          Waiting room: your queued tasks will start as your running slot opens up.
        </p>
      </section>

      <section :if={@bootstrap_history != []} class="rounded border p-4 space-y-2">
        <h2 class="text-lg font-semibold">Recent bootstrap runs</h2>

        <ul class="text-sm space-y-1">
          <li :for={s <- @bootstrap_history} id={"boot-#{s.id}"}>
            <span class="text-base-content/60">
              {Calendar.strftime(s.queued_at || s.inserted_at, "%Y-%m-%d %H:%M")}
            </span>
            — {s.bootstrap_kind || s.kind} — <span class={status_class(s.status)}>{s.status}</span>
          </li>
        </ul>
      </section>
    </div>
    """
  end

  defp status_class(:running), do: "text-blue-600"
  defp status_class(:queued), do: "text-yellow-600"
  defp status_class(:completed), do: "text-green-600"
  defp status_class(:failed), do: "text-red-600"
  defp status_class(_), do: "text-base-content/60"
end
