defmodule CamelotWeb.AgentLive.Show do
  @moduledoc """
  Agent detail LiveView with status and session history.
  """
  use CamelotWeb, :live_view

  alias Camelot.Accounts.User
  alias Camelot.Agents.Agent
  alias CamelotWeb.Scope

  require Ash.Query

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case load_or_forbid(id, socket.assigns.current_user) do
      {:ok, agent} ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(Camelot.PubSub, "agent:#{id}")
        end

        {:ok,
         assign(socket,
           page_title: agent.name,
           agent: agent
         )}

      :forbidden ->
        {:ok,
         socket
         |> put_flash(:error, "Agent not found")
         |> push_navigate(to: ~p"/agents")}
    end
  end

  defp load_or_forbid(id, %User{role: :admin}), do: {:ok, Ash.get!(Agent, id, load: [:project, :template, :sessions])}

  defp load_or_forbid(id, %User{} = user) do
    case Agent
         |> Ash.Query.filter(id == ^id)
         |> Scope.scope_agents(user)
         |> Ash.read_one(load: [:project, :template, :sessions]) do
      {:ok, %Agent{} = agent} -> {:ok, agent}
      _ -> :forbidden
    end
  end

  @impl true
  def handle_info({:agent_updated, agent}, socket) do
    agent = Ash.load!(agent, [:project, :template, :sessions])
    {:noreply, assign(socket, agent: agent)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("reset_agent", _params, socket) do
    agent = socket.assigns.agent

    case Ash.update(agent, %{}, action: :mark_idle) do
      {:ok, updated} ->
        updated = Ash.load!(updated, [:project, :template, :sessions])
        {:noreply, assign(socket, agent: updated)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to reset agent")}
    end
  end

  def handle_event("save_max_retries", %{"max_retries" => raw}, socket) do
    case Integer.parse(raw) do
      {n, ""} when n >= 0 ->
        agent = socket.assigns.agent

        case Ash.update(agent, %{max_retries: n}, action: :update) do
          {:ok, updated} ->
            updated = Ash.load!(updated, [:project, :template, :sessions])

            {:noreply,
             socket
             |> put_flash(:info, "Max retries set to #{n}")
             |> assign(agent: updated)}

          {:error, error} ->
            {:noreply, put_flash(socket, :error, "Failed to save: #{inspect(error)}")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Max retries must be ≥ 0")}
    end
  end

  defp template_name(agent) do
    case Ash.Resource.loaded?(agent, :template) && agent.template do
      %{name: name} -> name
      _ -> "—"
    end
  end

  defp override_summary(agent) do
    Enum.reject(
      [
        {"command prefix", agent.command_prefix_override},
        {"executable", agent.executable_override},
        {"base args", agent.base_args_override},
        {"env vars", agent.env_vars_override},
        {"permission args", agent.permission_args_by_stage_override},
        {"internal tools", agent.internal_tools_override},
        {"retry delay (ms)", agent.base_retry_delay_ms_override}
      ],
      fn {_label, value} -> is_nil(value) end
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <div>
          <.link
            navigate={~p"/agents"}
            class="text-sm text-base-content/60"
          >
            &larr; Back to agents
          </.link>
          <h1 class="text-2xl font-bold">{@agent.name}</h1>
        </div>
        <div class="flex items-center gap-2">
          <span class={[
            "badge",
            @agent.status == :idle && "badge-success",
            @agent.status == :busy && "badge-warning"
          ]}>
            {@agent.status}
          </span>
          <button
            phx-click="reset_agent"
            data-confirm="Reset agent to idle?"
            class="btn btn-xs btn-ghost text-warning"
          >
            Reset
          </button>
        </div>
      </div>

      <.list>
        <:item title="Template">{template_name(@agent)}</:item>
        <:item title="Project">
          {if Ash.Resource.loaded?(@agent, :project), do: @agent.project.name, else: "—"}
        </:item>
        <:item title="Status">{@agent.status}</:item>
      </.list>

      <form
        phx-submit="save_max_retries"
        class="flex items-end gap-3 rounded border p-3"
      >
        <label class="flex flex-col gap-1">
          <span class="text-sm text-base-content/60">Max retries</span>
          <input
            type="number"
            name="max_retries"
            min="0"
            value={@agent.max_retries}
            class="input input-sm w-24"
          />
        </label>
        <button type="submit" class="btn btn-sm btn-primary">Save</button>
        <p class="text-xs text-base-content/50 flex-1">
          0 = no retries. Applies to the next session this agent dispatches.
        </p>
      </form>

      <div :if={override_summary(@agent) != []} class="space-y-2">
        <h3 class="font-semibold">Project overrides</h3>
        <ul class="text-sm space-y-1">
          <li :for={{label, value} <- override_summary(@agent)}>
            <span class="text-base-content/60">{label}:</span>
            <code class="text-xs">{inspect(value)}</code>
          </li>
        </ul>
      </div>

      <div class="space-y-4">
        <h3 class="font-semibold">Recent Sessions</h3>
        <div
          :if={Ash.Resource.loaded?(@agent, :sessions) && @agent.sessions != []}
          class="space-y-2"
        >
          <div
            :for={session <- @agent.sessions}
            class="card bg-base-200 p-3"
          >
            <div class="flex items-center justify-between text-sm">
              <span class={[
                "badge badge-sm",
                session.status == :running && "badge-info",
                session.status == :completed && "badge-success",
                session.status == :failed && "badge-error",
                session.status == :cancelled && "badge-ghost"
              ]}>
                {session.status}
              </span>
              <span class="text-xs text-base-content/50">
                {if session.started_at,
                  do: Calendar.strftime(session.started_at, "%Y-%m-%d %H:%M"),
                  else: "—"}
              </span>
            </div>
            <pre
              :if={session.output_log}
              class="mt-2 text-xs overflow-auto max-h-40 bg-base-300 p-2 rounded"
            >{session.output_log}</pre>
          </div>
        </div>
        <p
          :if={!Ash.Resource.loaded?(@agent, :sessions) || @agent.sessions == []}
          class="text-sm text-base-content/50"
        >
          No sessions yet
        </p>
      </div>
    </div>
    """
  end
end
