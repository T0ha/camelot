defmodule CamelotWeb.TaskLive do
  @moduledoc """
  Task detail LiveView with stage/state transitions
  and session log streaming.
  """
  use CamelotWeb, :live_view

  import CamelotWeb.BoardComponents, only: [state_badge: 1]

  alias Camelot.Accounts.User
  alias Camelot.Agents.Session
  alias Camelot.Board.Task
  alias Camelot.Board.TaskMessage
  alias CamelotWeb.Scope

  require Ash.Query

  @task_load [:project, :agent, :creator, :sessions, :messages]

  # GFM extensions so plan/description markdown renders tables,
  # strikethrough, autolinks and task lists instead of raw text.
  @markdown_extensions [
    table: true,
    strikethrough: true,
    autolink: true,
    tasklist: true
  ]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case load_or_forbid(id, socket.assigns.current_user) do
      {:ok, task} ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(Camelot.PubSub, "task:#{id}")
        end

        socket =
          socket
          |> assign(
            page_title: task.title,
            task: task,
            message_input: "",
            live_output: "",
            subscribed_agent_id: nil,
            focused_column: :none
          )
          |> maybe_subscribe_agent(task)

        {:ok, socket}

      :forbidden ->
        {:ok,
         socket
         |> put_flash(:error, "Task not found")
         |> push_navigate(to: ~p"/")}
    end
  end

  defp load_or_forbid(id, %User{role: :admin}), do: {:ok, Ash.get!(Task, id, load: @task_load)}

  defp load_or_forbid(id, %User{} = user) do
    case Task
         |> Ash.Query.filter(id == ^id)
         |> Scope.scope_tasks(user)
         |> Ash.read_one(load: @task_load) do
      {:ok, %Task{} = task} -> {:ok, task}
      _ -> :forbidden
    end
  end

  @impl true
  def handle_info({:task_updated, task}, socket) do
    task =
      Ash.load!(task, [
        :project,
        :agent,
        :creator,
        :sessions,
        :messages
      ])

    {:noreply,
     socket
     |> assign(task: task)
     |> maybe_subscribe_agent(task)
     |> reset_live_output_unless_running(task)}
  end

  # Live agent output (one NDJSON chunk per broadcast). Accumulate,
  # bounded, for the running-session panel.
  def handle_info({:agent_output, _agent_id, chunk}, socket) do
    combined = socket.assigns.live_output <> to_string(chunk)
    {:noreply, assign(socket, live_output: cap_tail(combined, 20_000))}
  end

  # The assigned agent changed status (e.g. :idle <-> :busy). We
  # subscribe to its topic, so refresh the copy embedded in the task
  # to keep the card in sync (input controls key off agent.status).
  def handle_info({:agent_updated, agent}, socket) do
    {:noreply, assign(socket, task: %{socket.assigns.task | agent: agent})}
  end

  # Never crash the card on an unexpected PubSub message.
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("transition", %{"action" => action}, socket) do
    task = socket.assigns.task
    action = String.to_existing_atom(action)

    case Ash.update(task, %{}, action: action) do
      {:ok, updated} ->
        broadcast_update(updated)

        updated =
          Ash.load!(updated, [
            :project,
            :agent,
            :creator,
            :sessions,
            :messages
          ])

        {:noreply, assign(socket, task: updated)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Transition failed")}
    end
  end

  def handle_event("retry", _params, socket) do
    task = socket.assigns.task

    case Ash.update(task, %{}, action: :retry) do
      {:ok, updated} ->
        broadcast_update(updated)

        updated =
          Ash.load!(updated, [
            :project,
            :agent,
            :creator,
            :sessions,
            :messages
          ])

        {:noreply,
         socket
         |> assign(task: updated)
         |> put_flash(:info, "Task re-queued for retry")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Cannot retry right now")}
    end
  end

  def handle_event("respond_and_retry", params, socket) do
    task = socket.assigns.task

    tool_names =
      params
      |> Map.get("tools", "")
      |> String.split(",", trim: true)

    merged_tools =
      Enum.uniq((task.allowed_tools || []) ++ tool_names)

    answers =
      params
      |> Enum.filter(fn {k, _v} -> String.starts_with?(k, "q_") end)
      |> Enum.sort_by(fn {k, _v} -> k end)
      |> Enum.map_join("\n", fn {k, v} ->
        header = String.replace_prefix(k, "q_", "")
        "#{header}: #{v}"
      end)

    if answers != "" do
      Ash.create!(TaskMessage, %{
        role: :user,
        content: answers,
        task_id: task.id
      })
    end

    case Ash.update(
           task,
           %{allowed_tools: merged_tools},
           action: :provide_input
         ) do
      {:ok, updated} ->
        mark_session_clarified(params["session_id"])
        broadcast_update(updated)

        updated =
          Ash.load!(updated, [
            :project,
            :agent,
            :creator,
            :sessions,
            :messages
          ])

        {:noreply,
         socket
         |> assign(task: updated)
         |> put_flash(:info, "Queued for retry")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to queue task")}
    end
  end

  def handle_event("provide_input", %{"message" => msg}, socket) do
    task = socket.assigns.task
    msg = String.trim(msg)

    if msg == "" do
      {:noreply, socket}
    else
      Ash.create!(TaskMessage, %{
        role: :user,
        content: msg,
        task_id: task.id
      })

      case Ash.update(task, %{}, action: :provide_input) do
        {:ok, updated} ->
          broadcast_update(updated)

          updated =
            Ash.load!(updated, [
              :project,
              :agent,
              :creator,
              :sessions,
              :messages
            ])

          {:noreply, assign(socket, task: updated, message_input: "")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to send response")}
      end
    end
  end

  def handle_event("reset_task", _params, socket) do
    task = socket.assigns.task

    if not Ash.Resource.loaded?(task, :agent) or is_nil(task.agent) do
      {:noreply, put_flash(socket, :error, "No agent assigned")}
    else
      reset_task_and_agent(socket, task)
    end
  end

  def handle_event("cancel", _params, socket) do
    task = socket.assigns.task

    case Ash.update(task, %{}, action: :cancel) do
      {:ok, updated} ->
        broadcast_update(updated)

        updated =
          Ash.load!(updated, [
            :project,
            :agent,
            :creator,
            :sessions,
            :messages
          ])

        {:noreply, assign(socket, task: updated)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Cannot cancel task")}
    end
  end

  def handle_event("toggle_column", %{"col" => "left"}, socket) do
    {:noreply, toggle_focused_column(socket, :left)}
  end

  def handle_event("toggle_column", %{"col" => "right"}, socket) do
    {:noreply, toggle_focused_column(socket, :right)}
  end

  defp toggle_focused_column(socket, target) do
    next =
      case socket.assigns.focused_column do
        ^target -> :none
        _ -> target
      end

    assign(socket, focused_column: next)
  end

  defp grid_class(:none), do: "grid grid-cols-1 lg:grid-cols-2 gap-6"
  defp grid_class(_focused), do: "grid grid-cols-1 gap-6"

  defp column_hidden?(:left, :right), do: true
  defp column_hidden?(:right, :left), do: true
  defp column_hidden?(_col, _focused), do: false

  defp reset_task_and_agent(socket, task) do
    stop_agent_process(task.agent.id)

    with {:ok, _agent} <- Ash.update(task.agent, %{}, action: :mark_idle),
         {:ok, updated} <- Ash.update(task, %{}, action: :reset) do
      broadcast_update(updated)
      updated = Ash.load!(updated, @task_load)

      {:noreply,
       socket
       |> assign(task: updated)
       |> put_flash(:info, "Task reset — work will resume shortly")}
    else
      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to reset task")}
    end
  end

  defp stop_agent_process(agent_id) do
    case Camelot.Runtime.AgentSupervisor.stop_agent(agent_id) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  defp agent_stuck?(task) do
    Ash.Resource.loaded?(task, :agent) &&
      task.agent != nil &&
      task.agent.status == :busy &&
      task.state == :in_progress
  end

  defp broadcast_update(task) do
    Phoenix.PubSub.broadcast(
      Camelot.PubSub,
      "task:#{task.id}",
      {:task_updated, task}
    )

    Phoenix.PubSub.broadcast(
      Camelot.PubSub,
      "board",
      {:task_updated, task}
    )
  end

  defp available_transitions(task) do
    case {task.stage, task.state} do
      {:draft, _} ->
        [move_to_todo: "Move to Todo"]

      {:planning, :waiting_for_input} ->
        [approve_plan: "Approve Plan", request_plan_changes: "Request Changes"]

      {:pr, :waiting_for_input} ->
        [complete: "Approve PR", request_pr_changes: "Request Changes"]

      _ ->
        []
    end
  end

  defp stage_class(:draft), do: "badge-ghost"
  defp stage_class(:todo), do: "badge-ghost"
  defp stage_class(:planning), do: "badge-info"
  defp stage_class(:executing), do: "badge-primary"
  defp stage_class(:pr), do: "badge-secondary"
  defp stage_class(:done), do: "badge-success"
  defp stage_class(:cancelled), do: "badge-ghost"
  defp stage_class(_stage), do: "badge-ghost"

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns, :transitions, available_transitions(assigns.task))

    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <div>
          <.link navigate={~p"/"} class="text-sm text-base-content/60">
            &larr; Back to board
          </.link>
          <h1 class="text-2xl font-bold">{@task.title}</h1>
        </div>
        <div class="flex gap-2">
          <button
            :for={{action, label} <- @transitions}
            phx-click="transition"
            phx-value-action={action}
            class="btn btn-sm btn-primary"
          >
            {label}
          </button>
          <button
            :if={agent_stuck?(@task)}
            phx-click="reset_task"
            data-confirm="Reset task and agent? Work will resume from this stage."
            class="btn btn-sm btn-ghost text-warning"
          >
            Reset Task
          </button>
          <button
            :if={@task.state == :error}
            phx-click="retry"
            class="btn btn-sm btn-warning"
          >
            Retry
          </button>
          <button
            :if={@task.stage not in [:done, :cancelled]}
            phx-click="cancel"
            data-confirm="Cancel this task?"
            class="btn btn-sm btn-ghost text-error"
          >
            Cancel
          </button>
        </div>
      </div>

      <div class={grid_class(@focused_column)}>
        <div class={[
          "space-y-4",
          column_hidden?(:left, @focused_column) && "hidden"
        ]}>
          <div class="flex justify-end">
            <button
              type="button"
              phx-click="toggle_column"
              phx-value-col="left"
              class="btn btn-xs btn-ghost"
              aria-label="Toggle details column full-width"
              title={
                if @focused_column == :left,
                  do: "Restore split view",
                  else: "Expand to full width"
              }
            >
              <.icon
                name={
                  if @focused_column == :left,
                    do: "hero-arrows-pointing-in",
                    else: "hero-arrows-pointing-out"
                }
                class="size-4"
              />
            </button>
          </div>
          <.list>
            <:item title="Stage">
              <span class={["badge", stage_class(@task.stage)]}>
                {@task.stage}
              </span>
            </:item>
            <:item title="State">
              <.state_badge :if={@task.state} state={@task.state} />
              <span :if={is_nil(@task.state)} class="text-base-content/50">
                —
              </span>
            </:item>
            <:item title="Priority">{@task.priority}</:item>
            <:item title="Project">
              {if Ash.Resource.loaded?(@task, :project), do: @task.project.name, else: "—"}
            </:item>
            <:item title="Creator">
              {if Ash.Resource.loaded?(@task, :creator), do: to_string(@task.creator.email), else: "—"}
            </:item>
            <:item :if={@task.pr_url} title="Pull Request">
              <a href={@task.pr_url} target="_blank" class="link">
                PR #{@task.pr_number}
              </a>
            </:item>
          </.list>

          <div :if={@task.description} class="prose max-w-none overflow-x-auto">
            <h3>Description</h3>
            {render_markdown(@task.description)}
          </div>

          <div :if={@task.plan} class="prose max-w-none overflow-x-auto">
            <h3>Plan</h3>
            {render_markdown(@task.plan)}
          </div>

          <div
            :if={sorted_messages(@task) != []}
            class="space-y-3"
          >
            <h3 class="font-semibold">Conversation</h3>
            <div
              :for={msg <- sorted_messages(@task)}
              class={[
                "p-3 rounded-lg text-sm",
                if(msg.role == :assistant,
                  do: "bg-base-200 mr-8",
                  else: "bg-primary/10 ml-8"
                )
              ]}
            >
              <span class="font-semibold text-xs uppercase opacity-60">
                {msg.role}
              </span>
              <p class="mt-1 whitespace-pre-wrap">{msg.content}</p>
            </div>
          </div>

          <form
            :if={@task.state == :waiting_for_input}
            phx-submit="provide_input"
            class="flex gap-2"
          >
            <input
              type="text"
              name="message"
              value={@message_input}
              placeholder="Type your response..."
              class="input input-bordered flex-1"
              autofocus
            />
            <button type="submit" class="btn btn-primary">
              Send
            </button>
          </form>
        </div>

        <div class={[
          "space-y-4",
          column_hidden?(:right, @focused_column) && "hidden"
        ]}>
          <div class="flex items-center justify-between">
            <h3 class="font-semibold">Sessions</h3>
            <button
              type="button"
              phx-click="toggle_column"
              phx-value-col="right"
              class="btn btn-xs btn-ghost"
              aria-label="Toggle sessions column full-width"
              title={
                if @focused_column == :right,
                  do: "Restore split view",
                  else: "Expand to full width"
              }
            >
              <.icon
                name={
                  if @focused_column == :right,
                    do: "hero-arrows-pointing-in",
                    else: "hero-arrows-pointing-out"
                }
                class="size-4"
              />
            </button>
          </div>
          <div
            :if={Ash.Resource.loaded?(@task, :sessions) && @task.sessions != []}
            class="space-y-2"
          >
            <div
              :for={session <- sorted_sessions(@task)}
              class="card bg-base-200 p-3"
            >
              <div class="flex items-center justify-between text-sm">
                <div class="flex items-center gap-1">
                  <span class={[
                    "badge badge-sm",
                    session_status_class(session.status)
                  ]}>
                    {session.status}
                  </span>
                  <span
                    :if={session.retry_number > 0}
                    class="badge badge-sm badge-outline"
                  >
                    retry #{session.retry_number}
                  </span>
                </div>
                <span :if={session.exit_code} class="text-xs">
                  exit: {session.exit_code}
                </span>
              </div>
              <div
                :if={session.error_message}
                class="mt-2 text-xs text-error bg-error/10 p-2 rounded"
              >
                {session.error_message}
              </div>
              <div
                :if={session.clarified && has_denials?(session)}
                class="mt-2 text-xs text-success"
              >
                Clarified
              </div>
              <form
                :if={
                  has_denials?(session) && !session.clarified &&
                    @task.stage not in [:done, :cancelled]
                }
                phx-submit="respond_and_retry"
                class="mt-2 p-3 rounded bg-base-300/50 border border-base-content/10 space-y-4"
              >
                <input type="hidden" name="session_id" value={session.id} />
                <input
                  :if={has_tool_denials?(session)}
                  type="hidden"
                  name="tools"
                  value={denied_tools_csv(session)}
                />
                <div :if={has_question_denials?(session)}>
                  <p class="text-sm font-semibold text-info mb-2">
                    Agent needs your input
                  </p>
                  <div
                    :for={q <- extract_questions(session)}
                    class="mb-3"
                  >
                    <p class="text-sm font-semibold mb-1">
                      {q["header"]}
                    </p>
                    <p class="text-xs text-base-content/60 mb-1">
                      {q["question"]}
                    </p>
                    <div class="space-y-1">
                      <label
                        :for={opt <- q["options"] || []}
                        class="flex items-start gap-2 cursor-pointer"
                      >
                        <input
                          type="radio"
                          name={"q_#{q["header"]}"}
                          value={opt["label"]}
                          class="radio radio-sm radio-info mt-0.5"
                        />
                        <span class="text-sm">
                          <span class="font-medium">
                            {opt["label"]}
                          </span>
                          <span
                            :if={opt["description"]}
                            class="text-base-content/60"
                          >
                            — {opt["description"]}
                          </span>
                        </span>
                      </label>
                    </div>
                  </div>
                </div>
                <div :if={has_tool_denials?(session)}>
                  <p class="text-xs font-semibold text-warning mb-1">
                    Permission Denials
                  </p>
                  <div class="flex flex-wrap gap-1 mb-2">
                    <span
                      :for={denial <- tool_denials(session)}
                      class="badge badge-sm badge-warning badge-outline"
                    >
                      {denial["tool_name"]}
                    </span>
                  </div>
                  <details class="text-xs">
                    <summary class="cursor-pointer text-base-content/60">
                      Details
                    </summary>
                    <div
                      :for={denial <- tool_denials(session)}
                      class="mt-1 p-1 bg-base-300 rounded"
                    >
                      <span class="font-mono font-semibold">
                        {denial["tool_name"]}
                      </span>
                      <pre class="text-xs overflow-auto max-h-20 mt-1">{Jason.encode!(denial["tool_input"], pretty: true)}</pre>
                    </div>
                  </details>
                </div>
                <button type="submit" class="btn btn-sm btn-primary">
                  Approve &amp; Retry
                </button>
              </form>
              <div
                :if={session.status == :running && @live_output != ""}
                class="mt-2 space-y-1"
              >
                <h4 class="text-xs font-semibold flex items-center gap-2">
                  Live output <span class="loading loading-dots loading-xs"></span>
                </h4>
                <pre class="text-xs overflow-auto max-h-40 bg-base-300 p-2 rounded whitespace-pre-wrap">{humanize_stream(@live_output)}</pre>
              </div>
              <pre
                :if={session.output_log}
                class="mt-2 text-xs overflow-auto max-h-40 bg-base-300 p-2 rounded"
              >{session.output_log}</pre>
            </div>
          </div>
          <p
            :if={!Ash.Resource.loaded?(@task, :sessions) || @task.sessions == []}
            class="text-sm text-base-content/50"
          >
            No sessions yet
          </p>
        </div>
      </div>
    </div>
    """
  end

  defp render_markdown(text) when is_binary(text) do
    case MDEx.to_html(text, extension: @markdown_extensions) do
      {:ok, html} -> Phoenix.HTML.raw(html)
      {:error, _} -> text
    end
  end

  defp render_markdown(_), do: ""

  defp sorted_sessions(task) do
    if Ash.Resource.loaded?(task, :sessions) do
      Enum.sort_by(task.sessions, & &1.inserted_at, {:desc, DateTime})
    else
      []
    end
  end

  # Subscribe to the running agent's live-output topic once the task
  # has an agent. Idempotent per agent id so a re-render/reassign
  # doesn't double-subscribe (which would duplicate every chunk).
  defp maybe_subscribe_agent(socket, %Task{agent_id: nil}), do: socket

  defp maybe_subscribe_agent(%{assigns: %{subscribed_agent_id: id}} = socket, %Task{agent_id: id}) do
    socket
  end

  defp maybe_subscribe_agent(socket, %Task{agent_id: agent_id}) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Camelot.PubSub, "agent:#{agent_id}")
    end

    assign(socket, subscribed_agent_id: agent_id)
  end

  # The live buffer is only meaningful while a session is actively
  # running; once the task leaves :in_progress the persisted
  # output_log takes over, so drop the buffer.
  defp reset_live_output_unless_running(socket, %Task{state: :in_progress}), do: socket
  defp reset_live_output_unless_running(socket, _task), do: assign(socket, live_output: "")

  defp cap_tail(str, max) do
    if String.length(str) > max do
      String.slice(str, -max, max)
    else
      str
    end
  end

  # Best-effort render of the NDJSON stream-json feed: surface
  # assistant text and tool calls, collapse other events to a marker,
  # and pass a trailing partial line through untouched.
  defp humanize_stream(text) do
    text
    |> String.split(~r/\r?\n/)
    |> Enum.map(&humanize_line/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp humanize_line(line) do
    case Jason.decode(line) do
      {:ok, %{"type" => "assistant", "message" => %{"content" => content}}} ->
        humanize_content(content)

      {:ok, %{"type" => "result", "result" => result}} when is_binary(result) ->
        result

      {:ok, %{"type" => type}} ->
        "· #{type}"

      {:ok, _} ->
        ""

      {:error, _} ->
        line
    end
  end

  defp humanize_content(content) when is_list(content) do
    content
    |> Enum.map(&humanize_block/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp humanize_content(_), do: ""

  defp humanize_block(%{"type" => "text", "text" => text}) when is_binary(text), do: text
  defp humanize_block(%{"type" => "tool_use", "name" => name}), do: "→ #{name}"
  defp humanize_block(_), do: ""

  defp mark_session_clarified(nil), do: :ok

  defp mark_session_clarified(session_id) do
    session = Ash.get!(Session, session_id)
    Ash.update!(session, %{}, action: :mark_clarified)
  end

  defp sorted_messages(task) do
    if Ash.Resource.loaded?(task, :messages) do
      Enum.sort_by(task.messages, & &1.inserted_at)
    else
      []
    end
  end

  @internal_tools ~w(ExitPlanMode EnterPlanMode)

  defp real_denials(session) do
    Enum.reject(session.permission_denials || [], &(&1["tool_name"] in @internal_tools))
  end

  defp has_denials?(session) do
    real_denials(session) != []
  end

  defp has_question_denials?(session) do
    Enum.any?(real_denials(session), &(&1["tool_name"] == "AskUserQuestion"))
  end

  defp has_tool_denials?(session) do
    Enum.any?(real_denials(session), &(&1["tool_name"] != "AskUserQuestion"))
  end

  defp tool_denials(session) do
    Enum.reject(real_denials(session), &(&1["tool_name"] == "AskUserQuestion"))
  end

  defp extract_questions(session) do
    session.permission_denials
    |> Enum.filter(&(&1["tool_name"] == "AskUserQuestion"))
    |> Enum.flat_map(fn d ->
      get_in(d, ["tool_input", "questions"]) || []
    end)
    |> Enum.uniq_by(& &1["header"])
  end

  defp denied_tools_csv(session) do
    session
    |> tool_denials()
    |> Enum.map(&tool_permission_spec/1)
    |> Enum.uniq()
    |> Enum.join(",")
  end

  defp tool_permission_spec(%{"tool_name" => "Bash", "tool_input" => input}) do
    case input do
      %{"command" => cmd} when is_binary(cmd) ->
        prefix = cmd |> String.split(" ", parts: 2) |> List.first()
        "Bash(#{prefix}:*)"

      _ ->
        "Bash"
    end
  end

  defp tool_permission_spec(%{"tool_name" => "Edit", "tool_input" => input}) do
    case input do
      %{"file_path" => path} when is_binary(path) ->
        "Edit(#{path})"

      _ ->
        "Edit"
    end
  end

  defp tool_permission_spec(%{"tool_name" => "Write", "tool_input" => input}) do
    case input do
      %{"file_path" => path} when is_binary(path) ->
        "Write(#{path})"

      _ ->
        "Write"
    end
  end

  defp tool_permission_spec(%{"tool_name" => name}), do: name

  defp session_status_class(status) do
    case status do
      :running -> "badge-info"
      :completed -> "badge-success"
      :failed -> "badge-error"
      :cancelled -> "badge-ghost"
      _ -> "badge-ghost"
    end
  end
end
