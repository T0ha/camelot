defmodule CamelotWeb.ProfileLive.Usage do
  @moduledoc """
  Profile screen for the usage limits cards are scheduled under: the
  user's time zone and, per agent, a weekly cap, run windows and a
  manual usage reading — see `docs/usage-scheduling.md`.
  """
  use CamelotWeb, :live_view

  alias Camelot.Agents.Agent
  alias Camelot.Agents.UsagePolicy
  alias Camelot.Agents.UsageSnapshots
  alias Camelot.TimeZone
  alias CamelotWeb.UsageScheduling
  alias Phoenix.LiveView.Socket

  # A manual reading with no known reset is assumed to cover a week.
  @manual_reading_days 7

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

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <h1 class="text-2xl font-bold">Usage limits</h1>

      <section id="usage-limits" class="rounded border p-4 space-y-4">
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
    </div>
    """
  end
end
