defmodule CamelotWeb.ProfileLive.Usage do
  @moduledoc """
  Profile screen for the usage limits cards are scheduled under: the
  user's time zone and, per agent, a cap on its quota window (weekly,
  or monthly for Kimi — see `UsageSnapshots.quota_window/1`), run
  windows, a manual usage reading and any usage-limit pause on its
  credential — see `docs/guides/usage-scheduling.md`.
  """
  use CamelotWeb, :live_view

  alias Camelot.Accounts.Credential
  alias Camelot.Agents.Agent
  alias Camelot.Agents.UsagePolicy
  alias Camelot.Agents.UsageSnapshots
  alias Camelot.TimeZone
  alias CamelotWeb.UsageScheduling
  alias Phoenix.LiveView.Socket

  @impl true
  @spec mount(map(), map(), Socket.t()) :: {:ok, Socket.t()}
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Usage limits")
     |> assign(:time_zones, TimeZone.zones())
     |> assign(:agents, Agent |> Ash.read!() |> Enum.sort_by(& &1.name))
     |> load_state()}
  end

  @impl true
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

  # Never crash the screen on an unexpected message.
  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp load_state(socket) do
    user = socket.assigns.current_user

    assign(socket,
      time_zone_form: to_form(%{"time_zone" => user.time_zone}, as: "tz"),
      usage_rows: usage_rows(user, socket.assigns.agents)
    )
  end

  # One row per agent: its policy form, the quota window it is capped
  # on, the effective snapshot of that window and any usage-limit
  # pause on the credential it runs on.
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
        quota: agent_quota(agent),
        snapshot: agent_snapshot(user, agent, now),
        limited: agent_limit(user, agent, now)
      }
    end)
  end

  defp usage_policy_form(agent, policy) do
    to_form(
      %{
        "agent_id" => agent.id,
        "weekly_cap_percent" => policy && policy.weekly_cap_percent,
        "current_percent" => "",
        "resets_on" => ""
      },
      as: "policy",
      id: "usage-policy-#{agent.slug}"
    )
  end

  defp agent_snapshot(user, %Agent{required_credential_kinds: [kind | _]}, now) do
    UsageSnapshots.effective_quota(user.id, kind, now)
  end

  defp agent_snapshot(_user, _agent, _now), do: nil

  defp agent_quota(%Agent{required_credential_kinds: [kind | _]}), do: UsageSnapshots.quota_window(kind)
  defp agent_quota(_agent), do: :weekly

  defp agent_limit(user, %Agent{required_credential_kinds: [kind | _]}, now) do
    user.id
    |> Credential.for_user_and_kind(kind)
    |> active_limit(now)
  end

  defp agent_limit(_user, _agent, _now), do: nil

  defp active_limit(%Credential{usage_limited_until: %DateTime{} = until} = credential, now) do
    if DateTime.after?(until, now) do
      %{until: until, window: credential.usage_limit_window}
    end
  end

  defp active_limit(_credential, _now), do: nil

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
      record_manual_reading(user, agent, params, now)
    end
  end

  defp record_manual_reading(user, agent, params, now) do
    with {:ok, resets_on} <- resets_on(params["resets_on"], user.time_zone) do
      user
      |> manual_reading(agent, UsageScheduling.parse_percent(params["current_percent"]), now)
      |> write_manual_reading(resets_on, now)
    end
  end

  defp manual_reading(_user, _agent, nil, _now), do: :none

  defp manual_reading(user, %Agent{required_credential_kinds: [kind | _]} = agent, percent, now) do
    {user, kind, agent_quota(agent), percent, agent_snapshot(user, agent, now)}
  end

  defp manual_reading(_user, _agent, _percent, _now), do: {:error, :no_credential_kind}

  defp write_manual_reading(:none, _resets_on, _now), do: :ok
  defp write_manual_reading({:error, _} = error, _resets_on, _now), do: error

  defp write_manual_reading({user, kind, window, percent, snapshot}, resets_on, now) do
    reading = %{
      window: window,
      used_percent: percent,
      resets_at: manual_resets_at(resets_on, snapshot, window, now)
    }

    case UsageSnapshots.record(user.id, kind, [reading], :manual) do
      {:ok, _snapshots} -> :ok
      error -> error
    end
  end

  # The "resets on" date is local midnight in the user's zone.
  defp resets_on(date, zone) when date in [nil, ""], do: TimeZone.local_input_to_utc(nil, zone)
  defp resets_on(date, zone), do: TimeZone.local_input_to_utc(date <> "T00:00", zone)

  # An entered reset date wins, then the reset already known for the
  # window; otherwise assume the reading starts a fresh window.
  defp manual_resets_at(%DateTime{} = resets_on, _snapshot, _window, _now), do: resets_on
  defp manual_resets_at(nil, %{resets_at: resets_at}, _window, _now), do: resets_at
  defp manual_resets_at(nil, nil, :monthly, now), do: DateTime.shift(now, month: 1)
  defp manual_resets_at(nil, nil, :weekly, now), do: DateTime.add(now, 7, :day)

  defp quota_title(:monthly), do: "Monthly"
  defp quota_title(:weekly), do: "Weekly"

  defp limit_label(nil), do: "Provider"
  defp limit_label(window), do: String.capitalize(window)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <h1 class="text-2xl font-bold">Usage limits</h1>

      <section id="usage-limits" class="rounded border p-4 space-y-4">
        <p class="text-sm text-base-content/60">
          Keep part of each provider's quota for your own use, and choose
          when cards may start. Claude Code and Codex are capped on their
          weekly quota, Kimi Code on its monthly one. Cards that would go
          over the cap or start outside a window stay queued until they may
          run; running cards are never stopped. Claude Code reports its
          usage on every run; for other agents, enter your current usage by
          hand — Camelot adds its own run time to it as an estimate.
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
            :if={row.limited}
            id={"usage-policy-#{row.agent.slug}-limited"}
            class="text-sm text-warning"
          >
            {limit_label(row.limited.window)} usage limit reached — cards on
            this key are paused until {TimeZone.format(row.limited.until, @current_user.time_zone)}.
          </p>

          <p
            id={"usage-policy-#{row.agent.slug}-snapshot"}
            class="text-sm text-base-content/60"
          >
            <span :if={row.snapshot}>
              {UsageScheduling.format_percent(row.snapshot.used_percent)} of the {row.quota} quota used
              <span class="badge badge-xs badge-ghost">{row.snapshot.source}</span>
              — resets {TimeZone.format(row.snapshot.resets_at, @current_user.time_zone)}
            </span>
            <span :if={is_nil(row.snapshot)}>No {row.quota} usage reading yet.</span>
          </p>

          <.simple_form
            for={row.form}
            phx-submit="save_usage_policy"
            id={"usage-policy-#{row.agent.slug}"}
          >
            <.input field={row.form[:agent_id]} type="hidden" />
            <div class="grid grid-cols-3 gap-4">
              <.input
                field={row.form[:weekly_cap_percent]}
                type="number"
                min="1"
                max="100"
                label={"#{quota_title(row.quota)} cap % (blank = no cap)"}
              />
              <.input
                field={row.form[:current_percent]}
                type="number"
                min="0"
                max="100"
                step="0.1"
                label={"Current #{row.quota} usage % (manual reading)"}
              />
              <.input
                field={row.form[:resets_on]}
                type="date"
                label="Quota resets on (blank = keep / assume a full window)"
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
    </div>
    """
  end
end
