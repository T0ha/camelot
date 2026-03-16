defmodule Camelot.Agents.Changes.DispatchTasks do
  @moduledoc """
  Ash generic action implementation that scans idle agents,
  finds matching pending tasks, and dispatches them.
  PR fix tasks have higher priority than new tasks.
  """
  use Ash.Resource.Actions.Implementation

  alias Camelot.Agents.Agent
  alias Camelot.Board.Task
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
      |> Ash.read!()
      |> Enum.filter(&(&1.project_id == project_id))

    pr_fix =
      tasks
      |> Enum.filter(&(&1.status == :pr_fix))
      |> Enum.sort_by(& &1.priority, :desc)
      |> List.first()

    case pr_fix do
      nil ->
        tasks
        |> Enum.filter(&(&1.status == :created))
        |> Enum.sort_by(& &1.priority, :desc)
        |> List.first()

      task ->
        task
    end
  end

  defp dispatch_task(agent, task) do
    ensure_agent_process(agent.id)

    prompt = build_prompt(task)

    case AgentProcess.dispatch(agent.id, task.id, prompt) do
      :ok ->
        Ash.update!(task, %{}, action: :start_planning)

        Ash.update!(task, %{},
          action: :assign_agent,
          arguments: %{agent_id: agent.id}
        )

        Logger.info("Dispatched task #{task.id} to agent #{agent.id}")

      {:error, reason} ->
        Logger.warning(
          "Failed to dispatch task #{task.id}: " <>
            "#{inspect(reason)}"
        )
    end
  end

  defp ensure_agent_process(agent_id) do
    case AgentRegistry.lookup(agent_id) do
      nil -> AgentSupervisor.start_agent(agent_id)
      _pid -> :ok
    end
  end

  defp build_prompt(task) do
    parts = ["Task: #{task.title}"]

    parts =
      if task.description do
        parts ++ ["\nDescription: #{task.description}"]
      else
        parts
      end

    parts =
      if task.plan do
        parts ++ ["\nPlan: #{task.plan}"]
      else
        parts
      end

    Enum.join(parts)
  end
end
