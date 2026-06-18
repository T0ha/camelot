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
  alias Camelot.Accounts.SshKeygen
  alias Camelot.Accounts.User.Changes.EnsureDefaultSshKey
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

    # Legacy-user backfill: users who registered before this feature
    # shipped reach /profile with no default SSH key. The change module
    # is idempotent and a no-op when one already exists.
    _ = EnsureDefaultSshKey.ensure_default_for(socket.assigns.current_user.id)

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

  def handle_event("open_rotate_modal", _params, socket) do
    {:noreply, assign(socket, :show_rotate_modal, true)}
  end

  def handle_event("close_rotate_modal", _params, socket) do
    {:noreply, assign(socket, :show_rotate_modal, false)}
  end

  def handle_event("confirm_rotate_ssh_key", _params, socket) do
    {:noreply, rotate_default_ssh_key(socket)}
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

    default_ssh_key =
      Enum.find(credentials, &(&1.kind == :ssh_private_key and &1.name == "default"))

    assign(socket,
      page_title: "Profile",
      credentials: credentials,
      default_ssh_key: default_ssh_key,
      show_rotate_modal: socket.assigns[:show_rotate_modal] || false,
      bootstrap_history: history,
      kinds: @credential_kinds,
      pool: pool_for(user),
      credential_form: empty_credential_form()
    )
  end

  defp rotate_default_ssh_key(socket) do
    user = socket.assigns.current_user

    %{private_key: priv, public_key: pub, fingerprint: fp, algorithm: algo} =
      SshKeygen.generate(comment: "camelot@#{user.id}")

    case socket.assigns.default_ssh_key do
      nil ->
        # Race: backfill must have failed earlier. Create rather than
        # error out on the user.
        {:ok, _} =
          Ash.create(Credential, %{
            user_id: user.id,
            kind: :ssh_private_key,
            name: "default",
            value: priv,
            metadata: %{
              "public_key" => String.trim(pub),
              "fingerprint" => fp,
              "algorithm" => algo,
              "source" => "server_generated",
              "generated_at" => DateTime.to_iso8601(DateTime.utc_now())
            }
          })

      cred ->
        {:ok, _} =
          cred
          |> Ash.Changeset.for_update(:rotate, %{
            value: priv,
            metadata: %{
              "public_key" => String.trim(pub),
              "fingerprint" => fp,
              "algorithm" => algo
            }
          })
          |> Ash.update()
    end

    SecretSync.reconcile(user.id, :ssh_private_key)

    socket
    |> assign(:show_rotate_modal, false)
    |> put_flash(:info, "SSH key regenerated")
    |> load_state()
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

      <section class="rounded border p-4 space-y-3">
        <h2 class="text-lg font-semibold">SSH key</h2>

        <p class="text-sm text-base-content/60">
          Camelot generates this Ed25519 keypair for you and mounts the
          private half into every runner — agents use it to clone git
          repos. Paste the public key into GitHub
          (<a class="link" href="https://github.com/settings/keys">SSH and GPG keys</a>) and any other Git host you want runners to reach.
        </p>

        <div :if={@default_ssh_key}>
          <label
            class="text-sm font-medium block mb-1"
            for="ssh-public-key"
          >
            Public key
          </label>
          <textarea
            id="ssh-public-key"
            readonly
            rows="2"
            class="textarea textarea-bordered w-full font-mono text-xs"
          >{@default_ssh_key.metadata["public_key"]}</textarea>

          <div class="flex items-center justify-between gap-2 mt-2 text-xs">
            <div class="text-base-content/60 space-y-0.5">
              <div>Fingerprint: <code>{@default_ssh_key.metadata["fingerprint"]}</code></div>
              <div>
                {ssh_key_timestamp_label(@default_ssh_key)}
              </div>
            </div>

            <div class="flex items-center gap-2">
              <.copy_button target="ssh-public-key" />
              <button
                class="btn btn-sm btn-warning"
                phx-click="open_rotate_modal"
                type="button"
              >
                Generate new key
              </button>
            </div>
          </div>
        </div>

        <div :if={is_nil(@default_ssh_key)} class="space-y-2">
          <p class="text-sm text-base-content/60">
            No SSH key yet — something went wrong generating one on
            sign-in. Click below to generate one now.
          </p>
          <button
            class="btn btn-sm btn-primary"
            phx-click="confirm_rotate_ssh_key"
            type="button"
          >
            Generate key
          </button>
        </div>
      </section>

      <.modal
        id="rotate-ssh-key-modal"
        show={@show_rotate_modal}
        on_cancel={JS.push("close_rotate_modal")}
      >
        <div class="space-y-4">
          <h3 class="text-lg font-semibold">Replace your SSH key?</h3>
          <p class="text-sm">
            This will revoke the current keypair and generate a new one.
            <strong>The old key stops working immediately</strong>
            — anywhere
            it's installed (GitHub, deploy keys, <code>authorized_keys</code>
            files) must be updated with the new public key, or runners
            using those targets will fail to clone.
          </p>
          <div class="flex justify-end gap-2">
            <button
              type="button"
              class="btn btn-sm btn-ghost"
              phx-click="close_rotate_modal"
            >
              Cancel
            </button>
            <button
              type="button"
              class="btn btn-sm btn-error"
              phx-click="confirm_rotate_ssh_key"
            >
              Generate new key
            </button>
          </div>
        </div>
      </.modal>

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

  defp ssh_key_timestamp_label(%{metadata: meta} = cred) do
    case meta["rotated_at"] do
      iso when is_binary(iso) -> "Rotated: " <> format_iso(iso)
      _ -> "Generated: " <> generated_at(meta, cred.inserted_at)
    end
  end

  defp generated_at(%{"generated_at" => iso}, _fallback) when is_binary(iso) do
    format_iso(iso)
  end

  defp generated_at(_meta, fallback), do: Calendar.strftime(fallback, "%Y-%m-%d")

  defp format_iso(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
      _ -> iso
    end
  end
end
