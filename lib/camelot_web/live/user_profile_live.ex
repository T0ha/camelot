defmodule CamelotWeb.UserProfileLive do
  @moduledoc """
  Per-user profile page: manage credentials, see runner
  pool status, view bootstrap session history, and set the
  usage limits cards are scheduled under (time zone, and per
  agent a weekly cap, run windows and a manual usage reading
  — see `docs/usage-scheduling.md`).

  Credentials are encrypted at rest via `AshCloak`.
  When a credential changes, `SecretSync` async-pushes
  the new value into the Swarm secret so any future
  runner spawn picks it up.
  """
  use CamelotWeb, :live_view

  alias Camelot.Accounts.Credential
  alias Camelot.Accounts.SshKeygen
  alias Camelot.Accounts.User.Changes.EnsureDefaultSshKey
  alias Camelot.Agents.Agent
  alias Camelot.Agents.Session
  alias Camelot.Agents.UsagePolicy
  alias Camelot.Agents.UsageSnapshots
  alias Camelot.Github.AppConfig
  alias Camelot.Github.Installation
  alias Camelot.Runtime.RunnerPool
  alias Camelot.Runtime.SecretSync
  alias Camelot.Telemetry.Capture
  alias Camelot.TimeZone
  alias CamelotWeb.GithubSetupController
  alias CamelotWeb.UsageScheduling
  alias Phoenix.LiveView.Socket

  require Ash.Query

  # A manual reading with no known reset is assumed to cover a week.
  @manual_reading_days 7

  @credential_kinds [
    :claude_api_key,
    :openai_api_key,
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

  @doc false
  # The raw atom names don't say which agent CLI reads which key, which
  # is how a user could pick a kind no agent was looking for and see
  # only a bare 401 from the CLI.
  @spec kind_label(atom()) :: String.t()
  def kind_label(:claude_api_key), do: "claude_api_key — Claude Code"
  def kind_label(:openai_api_key), do: "openai_api_key — Codex"
  def kind_label(:ssh_private_key), do: "ssh_private_key — git over SSH"
  def kind_label(kind), do: Atom.to_string(kind)

  @impl true
  def handle_info(:pool_changed, socket) do
    {:noreply, assign(socket, :pool, pool_for(socket.assigns.current_user))}
  end

  # Never crash the profile page on an unexpected PubSub message.
  def handle_info(_msg, socket), do: {:noreply, socket}

  # The connect button is a plain link out to GitHub, so this is the
  # only point at which the app sees the attempt at all: without it a
  # user who abandons GitHub's install screen is indistinguishable
  # from one who never clicked. The `href` navigation is unaffected.
  @impl true
  def handle_event("github_setup_started", _params, socket) do
    Capture.capture("github_setup_started", socket.assigns.current_user, %{})

    {:noreply, socket}
  end

  def handle_event("create_credential", %{"credential" => params}, socket) do
    attrs = %{
      kind: parse_kind(params["kind"]),
      name: params["name"],
      value: params["value"]
    }

    case Ash.create(Credential, Map.put(attrs, :user_id, socket.assigns.current_user.id)) do
      {:ok, cred} ->
        SecretSync.reconcile(socket.assigns.current_user.id, cred.kind)
        # A Claude key is one of the setup guide's four steps, and this
        # is the only place it gets added. Without the nudge the strip
        # keeps showing it outstanding until the next navigation, and
        # `onboarding_step_completed` never sees the transition at all.
        send(self(), {:onboarding, :refresh})

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

  def handle_event("update_notification_prefs", %{"prefs" => params}, socket) do
    attrs =
      Map.take(params, [
        "notify_on_waiting_for_input",
        "notify_on_error",
        "notify_on_done",
        "notify_on_usage_limit_paused",
        "notify_on_usage_limit_resumed"
      ])

    case Ash.update(socket.assigns.current_user, attrs,
           action: :update_notification_preferences,
           actor: socket.assigns.current_user
         ) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(:current_user, user)
         |> put_flash(:info, "Preferences saved")
         |> load_state()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to save preferences")}
    end
  end

  def handle_event("set_time_zone", %{"tz" => %{"time_zone" => zone}}, socket) do
    case Ash.update(socket.assigns.current_user, %{time_zone: zone},
           action: :set_time_zone,
           actor: socket.assigns.current_user
         ) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(:current_user, user)
         |> put_flash(:info, "Time zone saved")
         |> load_state()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Unknown time zone")}
    end
  end

  def handle_event("save_usage_policy", %{"policy" => params}, socket) do
    agent = Enum.find(socket.assigns.agents, &(&1.id == params["agent_id"]))

    case save_usage_policy(socket.assigns.current_user, agent, params) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Usage limits saved")
         |> load_state()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to save usage limits")}
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

  def handle_event("disconnect_github_app", %{"id" => id}, socket) do
    installation = Ash.get!(Installation, id, actor: socket.assigns.current_user)
    Ash.destroy!(installation, actor: socket.assigns.current_user)

    {:noreply,
     socket
     |> put_flash(:info, "GitHub App disconnected.")
     |> load_state()}
  end

  defp load_state(socket) do
    user = Ash.load!(socket.assigns.current_user, :github_installations, actor: socket.assigns.current_user)

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

    agents = Agent |> Ash.read!() |> Enum.sort_by(& &1.name)

    default_ssh_key =
      Enum.find(credentials, &(&1.kind == :ssh_private_key and &1.name == "default"))

    socket
    |> assign(
      page_title: "Profile",
      current_user: user,
      credentials: credentials,
      default_ssh_key: default_ssh_key,
      show_rotate_modal: socket.assigns[:show_rotate_modal] || false,
      bootstrap_history: history,
      kinds: @credential_kinds,
      pool: pool_for(user),
      credential_form: empty_credential_form(),
      notification_prefs_form: notification_prefs_form(user),
      time_zone_form: to_form(%{"time_zone" => user.time_zone}, as: "tz"),
      time_zones: TimeZone.zones(),
      agents: agents,
      usage_rows: usage_rows(user, agents),
      github_installations_count: length(user.github_installations),
      github_app_configured?: AppConfig.configured?(),
      github_connect_url: github_connect_url(user)
    )
    |> stream(:github_installations, user.github_installations, reset: true)
  end

  # One row per agent: its policy form and the effective weekly
  # snapshot of the credential it runs on.
  defp usage_rows(user, agents) do
    now = DateTime.utc_now()

    policies =
      UsagePolicy
      |> Ash.Query.for_read(:for_user, %{user_id: user.id})
      |> Ash.read!()
      |> Map.new(&{&1.agent_id, &1})

    Enum.map(agents, fn agent ->
      policy = Map.get(policies, agent.id)

      %{
        agent: agent,
        form: usage_policy_form(agent, policy),
        rows: UsageScheduling.editor_rows(policy && policy.windows, user.time_zone, now),
        snapshot: agent_snapshot(user, agent, now)
      }
    end)
  end

  defp usage_policy_form(agent, policy) do
    to_form(
      %{
        "agent_id" => agent.id,
        "weekly_cap_percent" => policy && policy.weekly_cap_percent,
        "current_percent" => ""
      },
      as: "policy",
      id: "usage-policy-#{agent.slug}"
    )
  end

  defp agent_snapshot(user, %Agent{required_credential_kinds: [kind | _]}, now) do
    UsageSnapshots.effective_weekly(user.id, kind, now)
  end

  defp agent_snapshot(_user, _agent, _now), do: nil

  defp save_usage_policy(_user, nil, _params), do: {:error, :unknown_agent}

  defp save_usage_policy(user, agent, params) do
    now = DateTime.utc_now()

    with {:ok, _policy} <-
           UsagePolicy
           |> Ash.Changeset.for_create(:upsert, %{
             user_id: user.id,
             agent_id: agent.id,
             weekly_cap_percent: UsageScheduling.parse_integer(params["weekly_cap_percent"]),
             windows: UsageScheduling.windows_from_params(params["windows"], user.time_zone, now)
           })
           |> Ash.create() do
      record_manual_reading(user, agent, UsageScheduling.parse_percent(params["current_percent"]), now)
    end
  end

  defp record_manual_reading(_user, _agent, nil, _now), do: :ok

  defp record_manual_reading(user, %Agent{required_credential_kinds: [kind | _]} = agent, percent, now) do
    reading = %{
      window: :weekly,
      used_percent: percent,
      resets_at: manual_resets_at(agent_snapshot(user, agent, now), now)
    }

    case UsageSnapshots.record(user.id, kind, [reading], :manual) do
      {:ok, _snapshots} -> :ok
      error -> error
    end
  end

  defp record_manual_reading(_user, _agent, _percent, _now), do: {:error, :no_credential_kind}

  # Keep the provider's reset when one is known; otherwise assume the
  # reading starts a fresh week.
  defp manual_resets_at(%{resets_at: resets_at}, _now), do: resets_at
  defp manual_resets_at(nil, now), do: DateTime.add(now, @manual_reading_days, :day)

  defp github_connect_url(user) do
    AppConfig.install_url(GithubSetupController.state_token(user.id))
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

  defp notification_prefs_form(user) do
    to_form(
      %{
        "notify_on_waiting_for_input" => user.notify_on_waiting_for_input,
        "notify_on_error" => user.notify_on_error,
        "notify_on_done" => user.notify_on_done,
        "notify_on_usage_limit_paused" => user.notify_on_usage_limit_paused,
        "notify_on_usage_limit_resumed" => user.notify_on_usage_limit_resumed
      },
      as: "prefs"
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
          {if @github_installations_count > 0,
            do: "Connect another organization",
            else: "Connect GitHub App"}
        </a>
      </section>

      <section id="credentials" class="rounded border p-4 space-y-3">
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
            options={Enum.map(@kinds, &{kind_label(&1), Atom.to_string(&1)})}
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

      <section class="rounded border p-4 space-y-3">
        <h2 class="text-lg font-semibold">Email notifications</h2>

        <p class="text-sm text-base-content/60">
          Get notified by email when one of your task cards needs
          attention.
        </p>

        <.simple_form
          for={@notification_prefs_form}
          phx-submit="update_notification_prefs"
          id="notification-prefs-form"
        >
          <.input
            field={@notification_prefs_form[:notify_on_waiting_for_input]}
            type="checkbox"
            label="Email me when a task needs input"
          />
          <.input
            field={@notification_prefs_form[:notify_on_error]}
            type="checkbox"
            label="Email me when a task errors"
          />
          <.input
            field={@notification_prefs_form[:notify_on_done]}
            type="checkbox"
            label="Email me when a task is done"
          />
          <.input
            field={@notification_prefs_form[:notify_on_usage_limit_paused]}
            type="checkbox"
            label="Email me when a provider usage limit pauses my tasks"
          />
          <.input
            field={@notification_prefs_form[:notify_on_usage_limit_resumed]}
            type="checkbox"
            label="Email me when my paused tasks resume"
          />
          <:actions>
            <.button>Save preferences</.button>
          </:actions>
        </.simple_form>
      </section>

      <section id="usage-limits" class="rounded border p-4 space-y-4">
        <h2 class="text-lg font-semibold">Usage limits</h2>

        <p class="text-sm text-base-content/60">
          Keep part of each provider's weekly quota for your own use, and
          choose when cards may start. Cards that would go over the cap or
          start outside a window stay queued until they may run; running
          cards are never stopped. Claude Code reports its weekly usage on
          every run; for other agents, enter your current usage by hand —
          Camelot adds its own run time to it as an estimate.
        </p>

        <.simple_form for={@time_zone_form} phx-submit="set_time_zone" id="time-zone-form">
          <.input
            field={@time_zone_form[:time_zone]}
            type="select"
            label="Time zone"
            options={@time_zones}
          />
          <:actions>
            <.button>Save time zone</.button>
          </:actions>
        </.simple_form>

        <div :for={row <- @usage_rows} class="border-t pt-3 space-y-2">
          <h3 class="font-medium">{row.agent.name}</h3>

          <p
            id={"usage-policy-#{row.agent.slug}-snapshot"}
            class="text-sm text-base-content/60"
          >
            <span :if={row.snapshot}>
              {UsageScheduling.format_percent(row.snapshot.used_percent)} of the weekly quota used
              <span class="badge badge-xs badge-ghost">{row.snapshot.source}</span>
              — resets {TimeZone.format(row.snapshot.resets_at, @current_user.time_zone)}
            </span>
            <span :if={is_nil(row.snapshot)}>No weekly usage reading yet.</span>
          </p>

          <.simple_form
            for={row.form}
            phx-submit="save_usage_policy"
            id={"usage-policy-#{row.agent.slug}"}
          >
            <.input field={row.form[:agent_id]} type="hidden" />
            <div class="grid grid-cols-2 gap-4">
              <.input
                field={row.form[:weekly_cap_percent]}
                type="number"
                min="1"
                max="100"
                label="Weekly cap % (blank = no cap)"
              />
              <.input
                field={row.form[:current_percent]}
                type="number"
                min="0"
                max="100"
                step="0.1"
                label="Current weekly usage % (manual reading)"
              />
            </div>
            <p class="text-xs text-base-content/60">
              Run windows, in {@current_user.time_zone} — none means any time.
              Stored in UTC, so a daylight-saving change shifts them by an hour
              until you save again.
            </p>
            <UsageScheduling.window_rows
              id={"usage-policy-#{row.agent.slug}-windows"}
              name="policy[windows]"
              rows={row.rows}
            />
            <:actions>
              <.button>Save usage limits</.button>
            </:actions>
          </.simple_form>
        </div>
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
