defmodule Camelot.Agents.Changes.DispatchTasks do
  @moduledoc """
  Ash generic action implementation that scans idle agents,
  finds matching pending tasks, and dispatches them.
  Only picks up queued tasks in dispatchable stages.
  """
  use Ash.Resource.Actions.Implementation

  alias Camelot.Agents.Agent
  alias Camelot.Board.Task
  alias Camelot.Github.Client
  alias Camelot.Prompts.Renderer
  alias Camelot.Runtime.AgentProcess
  alias Camelot.Runtime.AgentRegistry
  alias Camelot.Runtime.AgentSupervisor

  require Logger

  @dispatchable_stages [:todo, :planning, :executing, :pr]

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
    Task
    |> Ash.read!(load: [:messages, :project])
    |> Enum.filter(fn task ->
      task.project_id == project_id and
        task.state == :queued and
        task.stage in @dispatchable_stages
    end)
    |> Enum.sort_by(& &1.priority, :desc)
    |> List.first()
  end

  defp dispatch_task(agent, task) do
    case Ash.update(
           task,
           %{agent_id: agent.id},
           action: :begin_work
         ) do
      {:ok, task} ->
        broadcast_task_update(task)
        ensure_agent_process(agent.id)
        prompt = build_prompt(task)

        case AgentProcess.dispatch(
               agent.id,
               task.id,
               prompt,
               task.allowed_tools || []
             ) do
          :ok ->
            Logger.info("Dispatched task #{task.id} to agent #{agent.id}")

          {:error, reason} ->
            Logger.warning(
              "Failed to dispatch task #{task.id}: " <>
                "#{inspect(reason)}"
            )
        end

      {:error, error} ->
        Logger.warning(
          "Failed to begin work on task #{task.id}: " <>
            "#{inspect(error)}"
        )
    end
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
    slug = prompt_slug(task)

    variables = build_variables(task)

    base =
      case Renderer.render(slug, task.project_id, variables) do
        {:ok, prompt} -> prompt
        {:error, :template_not_found} -> fallback_prompt(task)
      end

    append_conversation(base, task.messages)
  end

  defp prompt_slug(%{stage: :pr}), do: "pr_review"

  defp prompt_slug(%{plan: plan}) when not is_nil(plan),
    do: "execution"

  defp prompt_slug(_task), do: "planning"

  defp build_variables(%{stage: :pr} = task) do
    comments = fetch_pr_comments(task)

    %{
      "title" => task.title || "",
      "description" => task.description || "",
      "plan" => task.plan || "",
      "pr_url" => task.pr_url || "",
      "pr_number" => to_string(task.pr_number || ""),
      "pr_comments" => comments
    }
  end

  defp build_variables(task) do
    %{
      "title" => task.title || "",
      "description" => task.description || "",
      "plan" => task.plan || ""
    }
  end

  defp fetch_pr_comments(task) do
    project = task.project

    case Client.list_pull_request_comments(
           project.github_owner,
           project.github_repo,
           task.pr_number
         ) do
      {:ok, comments} ->
        comments
        |> Enum.map(fn c ->
          "@#{get_in(c, ["user", "login"])}: " <>
            (c["body"] || "")
        end)
        |> Enum.join("\n\n---\n\n")

      {:error, _} ->
        ""
    end
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
