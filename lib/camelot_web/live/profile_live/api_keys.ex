defmodule CamelotWeb.ProfileLive.ApiKeys do
  @moduledoc """
  Profile screen for the user's API keys: one row per key type, each
  with an inline form to set or replace the key.

  The runner mounts a single Swarm secret per `(user, kind)` (see
  `Camelot.Runtime.SecretSync`), so a row maps to what really gets
  used. SSH keys are managed on their own screen
  (`CamelotWeb.ProfileLive.SshKey`).

  Values are encrypted at rest via `AshCloak`. When a key changes,
  `SecretSync` async-pushes the new value into the Swarm secret so any
  future runner spawn picks it up.
  """
  use CamelotWeb, :live_view

  alias Camelot.Accounts.Credential
  alias Camelot.Runtime.SecretSync
  alias Phoenix.LiveView.Socket

  require Ash.Query

  @impl true
  @spec mount(map(), map(), Socket.t()) :: {:ok, Socket.t()}
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "API keys")
     |> assign(:kinds, Credential.valid_kinds() -- [:ssh_private_key])
     |> load_rows()}
  end

  @impl true
  def handle_event("save_api_key", %{"kind" => kind, "value" => value}, socket) do
    user_id = socket.assigns.current_user.id

    with {:ok, kind} <- fetch_kind(socket.assigns.kinds, kind),
         {:ok, _credential} <- upsert_key(user_id, kind, value) do
      SecretSync.reconcile(user_id, kind)
      # A Claude key is one of the setup guide's four steps, and this
      # is the only place it gets added. Without the nudge the strip
      # keeps showing it outstanding until the next navigation, and
      # `onboarding_step_completed` never sees the transition at all.
      send(self(), {:onboarding, :refresh})

      {:noreply,
       socket
       |> put_flash(:info, "API key saved")
       |> load_rows()}
    else
      :error -> {:noreply, put_flash(socket, :error, "Unknown API key type")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to save API key")}
    end
  end

  def handle_event("delete_api_key", %{"kind" => kind}, socket) do
    user_id = socket.assigns.current_user.id

    case fetch_kind(socket.assigns.kinds, kind) do
      {:ok, kind} ->
        # A legacy user may hold several keys of one kind; the row shows
        # the newest, so remove them all or a hidden one stays mounted.
        user_id
        |> keys_of_kind(kind)
        |> Enum.each(&Ash.destroy!/1)

        SecretSync.reconcile(user_id, kind)

        {:noreply,
         socket
         |> put_flash(:info, "API key removed")
         |> load_rows()}

      :error ->
        {:noreply, put_flash(socket, :error, "Unknown API key type")}
    end
  end

  # Never crash the screen on an unexpected message, such as the
  # onboarding ones.
  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # Kinds come off the wire as strings: match against the allowed list
  # rather than converting client input to an atom.
  defp fetch_kind(kinds, string) do
    case Enum.find(kinds, &(Atom.to_string(&1) == string)) do
      nil -> :error
      kind -> {:ok, kind}
    end
  end

  defp upsert_key(user_id, kind, value) do
    case keys_of_kind(user_id, kind) do
      [] ->
        Ash.create(Credential, %{
          user_id: user_id,
          kind: kind,
          name: nil,
          value: value
        })

      [newest | _] ->
        Ash.update(newest, %{value: value}, action: :update)
    end
  end

  defp keys_of_kind(user_id, kind) do
    Credential
    |> Ash.Query.filter(user_id == ^user_id and kind == ^kind)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read!()
  end

  defp load_rows(socket) do
    user_id = socket.assigns.current_user.id
    kinds = socket.assigns.kinds

    by_kind =
      Credential
      |> Ash.Query.filter(user_id == ^user_id and kind in ^kinds)
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.read!()
      |> Enum.group_by(& &1.kind)

    rows =
      Enum.map(kinds, fn kind ->
        %{kind: kind, credential: by_kind |> Map.get(kind, []) |> List.first()}
      end)

    assign(socket, :rows, rows)
  end

  defp kind_label(:claude_api_key), do: "Claude API key — Claude Code"
  defp kind_label(:openai_api_key), do: "OpenAI API key — Codex"
  defp kind_label(:gemini_api_key), do: "Gemini API key — Antigravity"
  defp kind_label(:generic), do: "Generic"
  defp kind_label(kind), do: Atom.to_string(kind)

  defp save_label(nil), do: "Save"
  defp save_label(_credential), do: "Replace"

  defp format_date(datetime), do: Calendar.strftime(datetime, "%Y-%m-%d")

  defp format_datetime(datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <h1 class="text-2xl font-bold">API keys</h1>

      <section id="api-keys" class="rounded border p-4 space-y-3">
        <p class="text-sm text-base-content/60">
          API keys used by agents inside runner containers. Values are
          encrypted at rest and shipped to the cluster as Swarm secrets.
          Saving a key for a type that already has one replaces it.
        </p>

        <table class="w-full text-sm">
          <thead>
            <tr class="text-left">
              <th class="py-1">Key</th>
              <th class="py-1">Status</th>
              <th class="py-1">Set or replace</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={row <- @rows}
              class="border-t align-middle"
              id={"api-key-row-#{row.kind}"}
            >
              <td class="py-2">{kind_label(row.kind)}</td>
              <td class="py-2">
                <span :if={is_nil(row.credential)}>Not set</span>
                <span :if={row.credential}>
                  Set · added {format_date(row.credential.inserted_at)}
                </span>
                <span
                  :if={row.credential && row.credential.usage_limited_until}
                  class="badge badge-warning"
                >
                  Usage-limited until {format_datetime(row.credential.usage_limited_until)}
                </span>
              </td>
              <td class="py-2">
                <form
                  id={"api-key-form-#{row.kind}"}
                  phx-submit="save_api_key"
                  class="flex items-center gap-2"
                >
                  <input type="hidden" name="kind" value={row.kind} />
                  <input
                    type="password"
                    name="value"
                    required
                    autocomplete="off"
                    aria-label={"#{kind_label(row.kind)} value"}
                    class="input input-bordered input-sm"
                  />
                  <button type="submit" class="btn btn-sm btn-primary">
                    {save_label(row.credential)}
                  </button>
                </form>
              </td>
              <td class="py-2 text-right">
                <button
                  :if={row.credential}
                  type="button"
                  class="btn btn-sm btn-outline btn-error"
                  phx-click="delete_api_key"
                  phx-value-kind={row.kind}
                  data-confirm="Remove this API key?"
                >
                  Remove
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </section>
    </div>
    """
  end
end
