defmodule CamelotWeb.TaskLive do
  @moduledoc """
  Task detail LiveView with stage/state transitions
  and session log streaming.
  """
  use CamelotWeb, :live_view

  import CamelotWeb.BoardComponents, only: [state_badge: 1]

  alias Camelot.Agents.Session
  alias Camelot.Board.Task
  alias Camelot.Board.TaskMessage

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    task =
      Ash.get!(Task, id, load: [:project, :agent, :creator, :sessions, :messages])

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Camelot.PubSub, "task:#{id}")
    end

    {:ok,
     assign(socket,
       page_title: task.title,
       task: task,
       message_input: ""
     )}
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

    {:noreply, assign(socket, task: task)}
  end

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

  def handle_event("reset_agent", _params, socket) do
    task = socket.assigns.task

    if Ash.Resource.loaded?(task, :agent) && task.agent do
      case Ash.update(task.agent, %{}, action: :mark_idle) do
        {:ok, _} ->
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
           |> put_flash(:info, "Agent reset to idle")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to reset agent")}
      end
    else
      {:noreply, put_flash(socket, :error, "No agent assigned")}
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
            phx-click="reset_agent"
            data-confirm="Reset agent to idle?"
            class="btn btn-sm btn-ghost text-warning"
          >
            Reset Agent
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

      <div class="grid grid-cols-2 gap-6">
        <div class="space-y-4">
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

          <div :if={@task.description} class="prose max-w-none">
            <h3>Description</h3>
            {render_markdown(@task.description)}
          </div>

          <div :if={@task.plan} class="prose max-w-none">
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

        <div class="space-y-4">
          <h3 class="font-semibold">Sessions</h3>
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
    case MDEx.to_html(text) do
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
    (session.permission_denials || [])
    |> Enum.reject(&(&1["tool_name"] in @internal_tools))
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
