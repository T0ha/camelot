defmodule CamelotWeb.UserProfileLive do
  @moduledoc """
  Per-user profile page: manage credentials, see runner
  pool status, view bootstrap session history.

  Credentials are encrypted at rest via `AshCloak`.
  When a credential changes, `SecretSync` async-pushes
  the new value into the Swarm secret so any future
  runner spawn picks it up.
  """
  use CamelotWeb, :live_view

  alias Camelot.Accounts.Credential
  alias Camelot.Agents.Session
  alias Camelot.Runtime.RunnerPool
  alias Camelot.Runtime.SecretSync
  alias Phoenix.LiveView.Socket

  require Ash.Query

  @credential_kinds [
    :claude_api_key,
    :openai_api_key,
    :codex_api_key,
    :github_pat,
    :github_oauth,
    :ssh_private_key,
    :generic
  ]

  @impl true
  @spec mount(map(), map(), Socket.t()) :: {:ok, Socket.t()}
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Camelot.PubSub, "runner_pool")
    end

    {:ok, load_state(socket)}
  end

  @impl true
  def handle_info(:pool_changed, socket) do
    {:noreply, assign(socket, :pool, pool_for(socket.assigns.current_user))}
  end

  @impl true
  def handle_event("create_credential", %{"credential" => params}, socket) do
    attrs = %{
      kind: parse_kind(params["kind"]),
      name: params["name"],
      value: params["value"]
    }

    case Ash.create(Credential, Map.put(attrs, :user_id, socket.assigns.current_user.id)) do
      {:ok, cred} ->
        SecretSync.reconcile(socket.assigns.current_user.id, cred.kind)

        {:noreply,
         socket
         |> put_flash(:info, "Credential added")
         |> load_state()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to add credential")}
    end
  end

  def handle_event("delete_credential", %{"id" => id}, socket) do
    case Ash.get(Credential, id) do
      {:ok, cred} ->
        Ash.destroy!(cred)
        SecretSync.reconcile(socket.assigns.current_user.id, cred.kind)

        {:noreply,
         socket
         |> put_flash(:info, "Credential removed")
         |> load_state()}

      _ ->
        {:noreply, socket}
    end
  end

  defp load_state(socket) do
    user = socket.assigns.current_user

    credentials =
      Credential
      |> Ash.Query.filter(user_id == ^user.id)
      |> Ash.read!()

    history =
      Session
      |> Ash.Query.filter(user_id == ^user.id and kind == :bootstrap)
      |> Ash.Query.sort(queued_at: :desc)
      |> Ash.Query.limit(10)
      |> Ash.read!()

    assign(socket,
      page_title: "Profile",
      credentials: credentials,
      bootstrap_history: history,
      kinds: @credential_kinds,
      pool: pool_for(user),
      credential_form: empty_credential_form()
    )
  end

  defp empty_credential_form do
    to_form(%{"kind" => "claude_api_key", "name" => "", "value" => ""},
      as: "credential"
    )
  end

  defp pool_for(user) do
    snap = safe_snapshot()

    per_user =
      Map.get(snap.per_user, user.id, %{active: 0, max: snap.global.max, queued: 0})

    %{global: snap.global, user: per_user}
  end

  defp safe_snapshot do
    RunnerPool.snapshot()
  catch
    :exit, _ -> %{global: %{active: 0, max: 0}, per_user: %{}}
  end

  defp parse_kind(string) when is_binary(string) do
    String.to_existing_atom(string)
  rescue
    _ -> :generic
  end

  defp parse_kind(_), do: :generic

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <h1 class="text-2xl font-bold">Profile</h1>

      <section class="rounded border p-4 space-y-2">
        <h2 class="text-lg font-semibold">Runner capacity</h2>

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

      <section class="rounded border p-4 space-y-3">
        <h2 class="text-lg font-semibold">Credentials</h2>

        <p class="text-sm text-base-content/60">
          API keys and tokens used by agents inside runner containers. Values are
          encrypted at rest and shipped to the cluster as Swarm secrets.
        </p>

        <table :if={@credentials != []} class="w-full text-sm">
          <thead>
            <tr class="text-left">
              <th class="py-1">Kind</th>
              <th class="py-1">Name</th>
              <th class="py-1">Added</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={c <- @credentials} class="border-t" id={"cred-#{c.id}"}>
              <td class="py-2">{c.kind}</td>
              <td class="py-2">{c.name || "—"}</td>
              <td class="py-2">{Calendar.strftime(c.inserted_at, "%Y-%m-%d")}</td>
              <td class="py-2 text-right">
                <button
                  class="text-red-600 hover:underline"
                  phx-click="delete_credential"
                  phx-value-id={c.id}
                  data-confirm="Delete this credential?"
                >
                  Delete
                </button>
              </td>
            </tr>
          </tbody>
        </table>

        <p :if={@credentials == []} class="text-sm text-base-content/60">
          No credentials yet — add one below.
        </p>

        <.simple_form
          for={@credential_form}
          phx-submit="create_credential"
          id="credential-form"
        >
          <.input
            field={@credential_form[:kind]}
            type="select"
            label="Kind"
            options={Enum.map(@kinds, &{Atom.to_string(&1), Atom.to_string(&1)})}
          />
          <.input field={@credential_form[:name]} label="Name (optional)" />
          <.input
            field={@credential_form[:value]}
            label="Value"
            type="password"
            required
          />
          <:actions>
            <.button>Add credential</.button>
          </:actions>
        </.simple_form>
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
