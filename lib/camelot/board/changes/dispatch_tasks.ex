defmodule Camelot.Board.Changes.DispatchTasks do
  @moduledoc """
  Ash generic action implementation that scans dispatchable
  tasks and dispatches all of them, highest priority first.

  Concurrency is bounded independently by `Camelot.Runtime.RunnerPool`
  (keyed by task creator), not by this dispatcher — a task's agent CLI
  is fixed at creation time, so there's no per-agent idle/busy slot to
  gate on anymore. `RunnerPool` never refuses a dispatch; it queues.
  """
  use Ash.Resource.Actions.Implementation

  alias Camelot.Board.Task
  alias Camelot.Github.Client
  alias Camelot.Github.Resolver
  alias Camelot.Prompts.Renderer
  alias Camelot.Runtime.TaskRegistry
  alias Camelot.Runtime.TaskRunner
  alias Camelot.Runtime.TaskRunnerSupervisor

  require Logger

  @dispatchable_stages [:todo, :planning, :executing, :pr]

  @impl true
  @spec run(
          Ash.ActionInput.t(),
          keyword(),
          Ash.Resource.Actions.Implementation.Context.t()
        ) :: :ok
  def run(_input, _opts, _context) do
    dispatchable_tasks()
    |> Enum.sort_by(& &1.priority, :desc)
    |> Enum.each(&dispatch_task/1)

    :ok
  end

  defp dispatchable_tasks do
    Task
    |> Ash.read!(
      load: [:messages, :attachments, :project, creator: [:github_installations]],
      authorize?: false
    )
    |> Enum.filter(fn task ->
      task.state == :queued and task.stage in @dispatchable_stages
    end)
  end

  defp dispatch_task(task) do
    case Ash.update(task, %{}, action: :begin_work) do
      {:ok, task} ->
        broadcast_task_update(task)
        ensure_task_runner(task.id)
        prompt = build_prompt(task)

        case TaskRunner.dispatch(task.id, prompt, task.allowed_tools || []) do
          :ok ->
            Logger.info("Dispatched task #{task.id}")

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

  @doc """
  Resolves the GitHub App installation id from the task
  creator's connected installation, if any.
  """
  @spec installation_id(map()) :: integer() | nil
  def installation_id(%{creator: %{github_installations: installations}} = task) do
    Resolver.installation_id(installations, github_owner(task))
  end

  def installation_id(_task), do: nil

  defp github_owner(%{project: %{github_owner: owner}}), do: owner
  defp github_owner(_task), do: nil

  defp ensure_task_runner(task_id) do
    case TaskRegistry.lookup(task_id) do
      nil -> TaskRunnerSupervisor.start_task_runner(task_id)
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
      case Renderer.render(slug, task.project_id, task.creator_id, variables) do
        {:ok, prompt} -> prompt
        {:error, :template_not_found} -> fallback_prompt(task)
      end

    base
    |> append_branch_directive(task, slug)
    |> append_conversation(task.messages)
  end

  # Pin the working branch to a deterministic, task-scoped name so a
  # PR that the agent opens can be recovered from GitHub even when its
  # URL is missing from the final output (see TaskRunner fallback).
  defp append_branch_directive(prompt, task, "execution") do
    prompt <>
      "\n\nWork on a git branch named exactly `camelot/task-#{task.id}` " <>
      "and open the pull request from that branch."
  end

  defp append_branch_directive(prompt, _task, _slug), do: prompt

  defp prompt_slug(%{stage: :pr}), do: "pr_review"

  defp prompt_slug(%{plan: plan}) when not is_nil(plan), do: "execution"

  defp prompt_slug(_task), do: "planning"

  defp build_variables(%{stage: :pr} = task) do
    comments = fetch_pr_comments(task)

    %{
      "title" => task.title || "",
      "description" => task.description || "",
      "plan" => prompt_plan(task),
      "pr_url" => task.pr_url || "",
      "pr_number" => to_string(task.pr_number || ""),
      "pr_comments" => comments,
      "attachments" => attachments_block(task)
    }
  end

  defp build_variables(task) do
    %{
      "title" => task.title || "",
      "description" => task.description || "",
      "plan" => prompt_plan(task),
      "attachments" => attachments_block(task)
    }
  end

  @doc """
  Renders the attachments block listing filenames available to the
  agent under `.camelot/attachments/` in the workspace, or `""` when
  the task has none (the template renderer strips the resulting
  blank line).
  """
  @spec attachments_block(map()) :: String.t()
  def attachments_block(%{attachments: attachments}) when is_list(attachments) and attachments != [] do
    names = Enum.map_join(attachments, "\n", &"- #{&1.filename}")

    "Attachments (available under .camelot/attachments/ in the workspace):\n" <> names
  end

  def attachments_block(_task), do: ""

  # Prefer the full plan document captured from the agent's plan file
  # over `plan`, which may be only a pointer + summary.
  defp prompt_plan(task) do
    task.full_plan || task.plan || ""
  end

  defp fetch_pr_comments(task) do
    project = task.project
    opts = [installation_id: installation_id(task)]
    owner = project.github_owner
    repo = project.github_repo
    pr = task.pr_number

    issue = list_or_empty(Client.list_pull_request_comments(owner, repo, pr, opts))
    review = list_or_empty(Client.list_pull_request_review_comments(owner, repo, pr, opts))

    (issue ++ review)
    |> Enum.sort_by(& &1["created_at"])
    |> Enum.map_join("\n\n---\n\n", &format_pr_comment/1)
  end

  defp list_or_empty({:ok, comments}), do: comments
  defp list_or_empty({:error, _reason}), do: []

  # Inline review comments carry path/line; surface them so the agent
  # knows which code each note refers to.
  defp format_pr_comment(comment) do
    login = get_in(comment, ["user", "login"])
    "@#{login}#{comment_location(comment)}: " <> (comment["body"] || "")
  end

  @doc """
  Renders the ` (path:line)` locator for an inline review comment.

  Top-level issue comments have no `path` and render to an empty
  string; a review comment on an outdated line has `line == nil` and
  renders just the path.
  """
  @spec comment_location(map()) :: String.t()
  def comment_location(%{"path" => nil}), do: ""
  def comment_location(%{"path" => path, "line" => nil}), do: " (#{path})"
  def comment_location(%{"path" => path, "line" => line}), do: " (#{path}:#{line})"
  def comment_location(_comment), do: ""

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
        do: parts ++ ["\nPlan: #{prompt_plan(task)}"],
        else: parts

    parts =
      case attachments_block(task) do
        "" -> parts
        block -> parts ++ ["\n" <> block]
      end

    Enum.join(parts)
  end
end
