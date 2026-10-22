defmodule CamelotWeb.ProfileLive.SshKey do
  @moduledoc """
  Profile screen for the user's default SSH keypair: shows the public
  half and lets the user regenerate the pair.

  The private half is encrypted at rest via `AshCloak`; rotating it
  async-pushes the new value into the Swarm secret through
  `Camelot.Runtime.SecretSync`.
  """
  use CamelotWeb, :live_view

  alias Camelot.Accounts.Credential
  alias Camelot.Accounts.SshKeygen
  alias Camelot.Accounts.User.Changes.EnsureDefaultSshKey
  alias Camelot.Runtime.SecretSync
  alias Phoenix.LiveView.Socket

  require Ash.Query

  @impl true
  @spec mount(map(), map(), Socket.t()) :: {:ok, Socket.t()}
  def mount(_params, _session, socket) do
    # Legacy-user backfill: users who registered before this feature
    # shipped reach this screen with no default SSH key. The change
    # module is idempotent and a no-op when one already exists.
    _ = EnsureDefaultSshKey.ensure_default_for(socket.assigns.current_user.id)

    {:ok,
     socket
     |> assign(page_title: "SSH key", show_rotate_modal: false)
     |> load_state()}
  end

  @impl true
  def handle_event("open_rotate_modal", _params, socket) do
    {:noreply, assign(socket, :show_rotate_modal, true)}
  end

  def handle_event("close_rotate_modal", _params, socket) do
    {:noreply, assign(socket, :show_rotate_modal, false)}
  end

  def handle_event("confirm_rotate_ssh_key", _params, socket) do
    {:noreply, rotate_default_ssh_key(socket)}
  end

  # Never crash the screen on an unexpected message.
  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp load_state(socket) do
    user_id = socket.assigns.current_user.id

    default_ssh_key =
      Credential
      |> Ash.Query.filter(
        user_id == ^user_id and kind == :ssh_private_key and
          name == "default"
      )
      |> Ash.read_first!()

    assign(socket, :default_ssh_key, default_ssh_key)
  end

  defp rotate_default_ssh_key(socket) do
    user = socket.assigns.current_user

    keypair = SshKeygen.generate(comment: "camelot@#{user.id}")
    {:ok, _} = store_keypair(socket.assigns.default_ssh_key, user, keypair)

    SecretSync.reconcile(user.id, :ssh_private_key)

    socket
    |> assign(:show_rotate_modal, false)
    |> put_flash(:info, "SSH key regenerated")
    |> load_state()
  end

  # Race: the backfill must have failed earlier. Create rather than
  # error out on the user.
  defp store_keypair(nil, user, keypair) do
    Ash.create(Credential, %{
      user_id: user.id,
      kind: :ssh_private_key,
      name: "default",
      value: keypair.private_key,
      metadata:
        Map.merge(key_metadata(keypair), %{
          "source" => "server_generated",
          "generated_at" => DateTime.to_iso8601(DateTime.utc_now())
        })
    })
  end

  defp store_keypair(cred, _user, keypair) do
    cred
    |> Ash.Changeset.for_update(:rotate, %{
      value: keypair.private_key,
      metadata: key_metadata(keypair)
    })
    |> Ash.update()
  end

  defp key_metadata(%{public_key: pub, fingerprint: fp, algorithm: algo}) do
    %{
      "public_key" => String.trim(pub),
      "fingerprint" => fp,
      "algorithm" => algo
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <h1 class="text-2xl font-bold">SSH key</h1>

      <section class="rounded border p-4 space-y-3">
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
    </div>
    """
  end

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
