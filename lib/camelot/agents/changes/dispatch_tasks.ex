defmodule Camelot.Agents.Changes.DispatchTasks do
  @moduledoc """
  Ash generic action implementation that scans idle agents,
  finds matching pending tasks, and dispatches them.
  PR fix tasks have higher priority than new tasks.
  """
  use Ash.Resource.Actions.Implementation

  alias Camelot.Agents.Agent
  alias Camelot.Board.Task
  alias Camelot.Prompts.Renderer
  alias Camelot.Runtime.AgentProcess
  alias Camelot.Runtime.AgentRegistry
  alias Camelot.Runtime.AgentSupervisor

  require Logger

  @impl true
  @spec run(
          Ash.ActionInput.t(),
          keyword(),
          Ash.Resource.Actions.Implementation.Context.t()
        ) :: :ok
  def run(_input, _opts, _context) do
    idle_agents = fetch_idle_agents()

    Enum.each(idle_agents, fn agent ->
      case find_next_task(agent.project_id) do
        nil ->
          :ok

        task ->
          dispatch_task(agent, task)
      end
    end)

    :ok
  end

  defp fetch_idle_agents do
    Agent
    |> Ash.read!(load: [:project])
    |> Enum.filter(&(&1.status == :idle))
  end

  defp find_next_task(project_id) do
    tasks =
      Task
      |> Ash.read!(load: [:messages])
      |> Enum.filter(&(&1.project_id == project_id))

    pr_fix =
      tasks
      |> Enum.filter(&(&1.status == :pr_fix))
      |> Enum.sort_by(& &1.priority, :desc)
      |> List.first()

    case pr_fix do
      nil ->
        resumed =
          tasks
          |> Enum.filter(&resumed_planning?/1)
          |> Enum.sort_by(& &1.priority, :desc)
          |> List.first()

        resumed ||
          tasks
          |> Enum.filter(&(&1.status == :created))
          |> Enum.sort_by(& &1.priority, :desc)
          |> List.first()

      task ->
        task
    end
  end

  defp resumed_planning?(%{status: status, messages: messages})
       when status in [:planning, :executing] and is_list(messages) and messages != [] do
    last = Enum.max_by(messages, & &1.inserted_at)
    last.role == :user
  end

  defp resumed_planning?(_task), do: false

  defp dispatch_task(agent, task) do
    with {:ok, task} <- maybe_start_planning(task),
         {:ok, task} <-
           Ash.update(task, %{agent_id: agent.id}, action: :assign_agent) do
      broadcast_task_update(task)
      ensure_agent_process(agent.id)
      prompt = build_prompt(task)

      case AgentProcess.dispatch(agent.id, task.id, prompt) do
        :ok ->
          Logger.info("Dispatched task #{task.id} to agent #{agent.id}")

        {:error, reason} ->
          Logger.warning(
            "Failed to dispatch task #{task.id}: " <>
              "#{inspect(reason)}"
          )
      end
    else
      {:error, error} ->
        Logger.warning(
          "Failed to update task #{task.id}: " <>
            "#{inspect(error)}"
        )
    end
  end

  defp maybe_start_planning(%{status: :planning} = task) do
    {:ok, task}
  end

  defp maybe_start_planning(%{status: :executing} = task) do
    {:ok, task}
  end

  defp maybe_start_planning(%{status: :pr_fix} = task) do
    Ash.update(task, %{}, action: :start_pr_fix)
  end

  defp maybe_start_planning(task) do
    Ash.update(task, %{}, action: :start_planning)
  end

  defp ensure_agent_process(agent_id) do
    case AgentRegistry.lookup(agent_id) do
      nil -> AgentSupervisor.start_agent(agent_id)
      _pid -> :ok
    end
  end

  defp broadcast_task_update(task) do
    Phoenix.PubSub.broadcast(
      Camelot.PubSub,
      "board",
      {:task_updated, task}
    )

    Phoenix.PubSub.broadcast(
      Camelot.PubSub,
      "task:#{task.id}",
      {:task_updated, task}
    )
  end

  defp build_prompt(task) do
    slug =
      if task.plan,
        do: "execution",
        else: "planning"

    variables = %{
      "title" => task.title || "",
      "description" => task.description || "",
      "plan" => task.plan || ""
    }

    base =
      case Renderer.render(slug, task.project_id, variables) do
        {:ok, prompt} -> prompt
        {:error, :template_not_found} -> fallback_prompt(task)
      end

    append_conversation(base, task.messages)
  end

  defp append_conversation(prompt, messages) when is_list(messages) and messages != [] do
    sorted = Enum.sort_by(messages, & &1.inserted_at)

    history =
      Enum.map_join(sorted, "\n", fn msg ->
        label = if msg.role == :assistant, do: "Assistant", else: "User"
        "#{label}: #{msg.content}"
      end)

    prompt <>
      "\n\n--- Conversation History ---\n" <>
      history <>
      "\n\nPlease continue based on the conversation above."
  end

  defp append_conversation(prompt, _messages), do: prompt

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
end
