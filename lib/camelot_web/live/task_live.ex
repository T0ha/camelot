defmodule CamelotWeb.TaskLive do
  @moduledoc """
  Task detail LiveView with status transitions
  and session log streaming.
  """
  use CamelotWeb, :live_view

  alias Camelot.Board.Task
  alias Camelot.Board.TaskMessage
  alias Camelot.Prompts.Renderer
  alias Camelot.Runtime.AgentProcess
  alias Camelot.Runtime.AgentRegistry
  alias Camelot.Runtime.AgentSupervisor

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
      Ash.load!(task, [:project, :agent, :creator, :sessions, :messages])

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

    if Ash.Resource.loaded?(task, :agent) && task.agent do
      ensure_agent_process(task.agent.id)

      case AgentProcess.retry(task.agent.id) do
        :ok ->
          {:noreply, put_flash(socket, :info, "Retry started")}

        {:error, :no_task} ->
          redispatch(task, socket)

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Cannot retry right now")}
      end
    else
      {:noreply, put_flash(socket, :error, "No agent assigned")}
    end
  end

  def handle_event("approve_and_retry", %{"tools" => tools}, socket) do
    task = socket.assigns.task
    tool_names = String.split(tools, ",", trim: true)

    if Ash.Resource.loaded?(task, :agent) && task.agent do
      ensure_agent_process(task.agent.id)

      case AgentProcess.approve_and_retry(
             task.agent.id,
             tool_names
           ) do
        :ok ->
          {:noreply, put_flash(socket, :info, "Retrying with approved tools")}

        {:error, :no_task} ->
          {:noreply, put_flash(socket, :error, "No task to retry")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Cannot retry right now")}
      end
    else
      {:noreply, put_flash(socket, :error, "No agent assigned")}
    end
  end

  def handle_event("answer_questions", params, socket) do
    task = socket.assigns.task

    answers =
      params
      |> Enum.filter(fn {k, _v} -> String.starts_with?(k, "q_") end)
      |> Enum.sort_by(fn {k, _v} -> k end)
      |> Enum.map_join("\n", fn {k, v} ->
        header = String.replace_prefix(k, "q_", "")
        "#{header}: #{v}"
      end)

    if Ash.Resource.loaded?(task, :agent) && task.agent do
      ensure_agent_process(task.agent.id)

      case AgentProcess.answer_and_retry(task.agent.id, answers) do
        :ok ->
          {:noreply, put_flash(socket, :info, "Answers submitted, retrying")}

        {:error, :no_task} ->
          {:noreply, put_flash(socket, :error, "No task to retry")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Cannot retry right now")}
      end
    else
      {:noreply, put_flash(socket, :error, "No agent assigned")}
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

  defp redispatch(task, socket) do
    prompt = build_retry_prompt(task)
    ensure_agent_process(task.agent.id)

    case AgentProcess.dispatch(
           task.agent.id,
           task.id,
           prompt
         ) do
      :ok ->
        {:noreply, put_flash(socket, :info, "Retry started")}

      {:error, :busy} ->
        {:noreply, put_flash(socket, :error, "Agent is busy")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Cannot retry right now")}
    end
  end

  defp build_retry_prompt(task) do
    slug =
      if task.plan,
        do: "execution",
        else: "planning"

    variables = %{
      "title" => task.title || "",
      "description" => task.description || "",
      "plan" => task.plan || ""
    }

    case Renderer.render(slug, task.project_id, variables) do
      {:ok, prompt} -> prompt
      {:error, :template_not_found} -> fallback_prompt(task)
    end
  end

  defp fallback_prompt(task) do
    parts = ["Task: #{task.title}"]

    parts =
      if task.description,
        do: parts ++ ["\nDescription: #{task.description}"],
        else: parts

    parts =
      if task.plan,
        do: parts ++ ["\nPlan: #{task.plan}"],
        else: parts

    Enum.join(parts)
  end

  defp ensure_agent_process(agent_id) do
    case AgentRegistry.lookup(agent_id) do
      nil -> AgentSupervisor.start_agent(agent_id)
      _pid -> :ok
    end
  end

  defp agent_stuck?(task) do
    Ash.Resource.loaded?(task, :agent) &&
      task.agent != nil &&
      task.agent.status == :busy &&
      task.status not in [:done, :cancelled]
  end

  defp retryable?(task) do
    has_agent? =
      Ash.Resource.loaded?(task, :agent) && task.agent != nil

    has_failed_session? =
      Ash.Resource.loaded?(task, :sessions) &&
        Enum.any?(task.sessions, &(&1.status == :failed))

    has_agent? && has_failed_session? &&
      task.status not in [:done, :cancelled]
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

  defp available_transitions(:created), do: [start_planning: "Start Planning"]

  defp available_transitions(:planning), do: [submit_plan: "Submit Plan"]
  defp available_transitions(:needs_input), do: []

  defp available_transitions(:plan_review), do: [approve_plan: "Approve", reject_plan: "Reject"]

  defp available_transitions(:executing), do: [pr_created: "PR Created"]

  defp available_transitions(:pr_created), do: [submit_pr_review: "Submit for Review"]

  defp available_transitions(:pr_review), do: [approve_pr: "Approve PR", request_pr_changes: "Request Changes"]

  defp available_transitions(:pr_fix), do: [start_pr_fix: "Start Fix"]

  defp available_transitions(_status), do: []

  defp status_class(:needs_input), do: "badge-accent"
  defp status_class(:planning), do: "badge-info"
  defp status_class(:plan_review), do: "badge-warning"
  defp status_class(:executing), do: "badge-primary"
  defp status_class(:pr_created), do: "badge-secondary"
  defp status_class(:pr_review), do: "badge-warning"
  defp status_class(:pr_fix), do: "badge-error"
  defp status_class(:done), do: "badge-success"
  defp status_class(_status), do: "badge-ghost"

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :transitions, available_transitions(assigns.task.status))

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
            :if={retryable?(@task)}
            phx-click="retry"
            class="btn btn-sm btn-warning"
          >
            Retry
          </button>
          <button
            :if={@task.status not in [:done, :cancelled]}
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
            <:item title="Status">
              <span class={["badge", status_class(@task.status)]}>
                {@task.status}
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
            :if={@task.status == :needs_input}
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
              :for={session <- @task.sessions}
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
                :if={has_question_denials?(session)}
                class="mt-2 p-3 rounded bg-info/10 border border-info/30"
              >
                <p class="text-sm font-semibold text-info mb-2">
                  Agent needs your input
                </p>
                <form
                  :if={@task.status not in [:done, :cancelled]}
                  phx-submit="answer_questions"
                >
                  <div
                    :for={q <- extract_questions(session)}
                    class="mb-3"
                  >
                    <p class="text-sm font-semibold mb-1">{q["header"]}</p>
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
                          <span class="font-medium">{opt["label"]}</span>
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
                  <button type="submit" class="btn btn-sm btn-info">
                    Submit Answers & Retry
                  </button>
                </form>
              </div>
              <div
                :if={has_tool_denials?(session)}
                class="mt-2 p-2 rounded bg-warning/10 border border-warning/30"
              >
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
                <details class="text-xs mb-2">
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
                <button
                  :if={@task.status not in [:done, :cancelled]}
                  phx-click="approve_and_retry"
                  phx-value-tools={denied_tools_csv(session)}
                  class="btn btn-xs btn-warning"
                >
                  Approve &amp; Retry
                </button>
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
    case MDEx.to_html(text) do
      {:ok, html} -> Phoenix.HTML.raw(html)
      {:error, _} -> text
    end
  end

  defp render_markdown(_), do: ""

  defp sorted_messages(task) do
    if Ash.Resource.loaded?(task, :messages) do
      Enum.sort_by(task.messages, & &1.inserted_at)
    else
      []
    end
  end

  defp has_question_denials?(session) do
    is_list(session.permission_denials) &&
      Enum.any?(session.permission_denials, &(&1["tool_name"] == "AskUserQuestion"))
  end

  defp has_tool_denials?(session) do
    is_list(session.permission_denials) &&
      Enum.any?(session.permission_denials, &(&1["tool_name"] != "AskUserQuestion"))
  end

  defp tool_denials(session) do
    Enum.reject(session.permission_denials || [], &(&1["tool_name"] == "AskUserQuestion"))
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
      %{"file_path" => path} when is_binary(path) -> "Edit(#{path})"
      _ -> "Edit"
    end
  end

  defp tool_permission_spec(%{"tool_name" => "Write", "tool_input" => input}) do
    case input do
      %{"file_path" => path} when is_binary(path) -> "Write(#{path})"
      _ -> "Write"
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
