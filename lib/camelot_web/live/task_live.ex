defmodule CamelotWeb.TaskLive do
  @moduledoc """
  Task detail LiveView with status transitions
  and session log streaming.
  """
  use CamelotWeb, :live_view

  alias Camelot.Board.Task
  alias Camelot.Runtime.AgentProcess
  alias Camelot.Runtime.AgentRegistry
  alias Camelot.Runtime.AgentSupervisor

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    task = Ash.get!(Task, id, load: [:project, :agent, :creator, :sessions])

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Camelot.PubSub, "task:#{id}")
    end

    {:ok,
     assign(socket,
       page_title: task.title,
       task: task
     )}
  end

  @impl true
  def handle_info({:task_updated, task}, socket) do
    task = Ash.load!(task, [:project, :agent, :creator, :sessions])
    {:noreply, assign(socket, task: task)}
  end

  @impl true
  def handle_event("transition", %{"action" => action}, socket) do
    task = socket.assigns.task
    action = String.to_existing_atom(action)

    case Ash.update(task, %{}, action: action) do
      {:ok, updated} ->
        broadcast_update(updated)
        updated = Ash.load!(updated, [:project, :agent, :creator, :sessions])
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

  def handle_event("cancel", _params, socket) do
    task = socket.assigns.task

    case Ash.update(task, %{}, action: :cancel) do
      {:ok, updated} ->
        broadcast_update(updated)
        updated = Ash.load!(updated, [:project, :agent, :creator, :sessions])
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

  defp available_transitions(:plan_review), do: [approve_plan: "Approve", reject_plan: "Reject"]

  defp available_transitions(:executing), do: [pr_created: "PR Created"]

  defp available_transitions(:pr_created), do: [submit_pr_review: "Submit for Review"]

  defp available_transitions(:pr_review), do: [approve_pr: "Approve PR", request_pr_changes: "Request Changes"]

  defp available_transitions(:pr_fix), do: [start_pr_fix: "Start Fix"]

  defp available_transitions(_status), do: []

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
            <p>{@task.description}</p>
          </div>

          <div :if={@task.plan} class="prose max-w-none">
            <h3>Plan</h3>
            <pre class="whitespace-pre-wrap text-sm">{@task.plan}</pre>
          </div>
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
