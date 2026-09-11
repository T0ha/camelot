defmodule Camelot.Board.PromptBuilder do
  @moduledoc """
  Builds the prompt handed to the agent CLI for a task, chosen by the
  task's current stage: `planning`, `execution` (once a plan exists) or
  `pr_review`.

  Extracted from `Camelot.Board.Changes.DispatchTasks` so it has more
  than one caller: `Camelot.Runtime.TaskRunner` also needs it when it
  re-attaches to a session that survived a restart, since the prompt
  that session was dispatched with only ever lived in the memory of the
  process that died.
  """
  use CamelotWeb, :verified_routes

  alias Camelot.Board.Changes.CheckPrStatus
  alias Camelot.Board.Task
  alias Camelot.Github.Client
  alias Camelot.Github.Resolver
  alias Camelot.Prompts.Renderer

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

  @doc """
  Renders the prompt for `task`'s current stage.

  `task` must be loaded with `:messages`, `:attachments`, `:project`
  and `creator: [:github_installations]` — the PR-stage variables and
  the GitHub App installation lookup all read from those.
  """
  @spec build(Task.t()) :: String.t()
  def build(task) do
    slug = prompt_slug(task)

    variables = build_variables(task)

    base =
      case Renderer.render(slug, task.project_id, task.creator_id, variables) do
        {:ok, prompt} -> prompt
        {:error, :template_not_found} -> fallback_prompt(task)
      end

    base
    |> append_branch_directive(task, slug)
    |> append_conflict_directive(task)
    |> append_related_context(task)
    |> append_conversation(task.messages)
  end

  # A PR-stage task whose PR has merge conflicts must be told so
  # explicitly: the pr_review prompt otherwise only mentions comments and
  # CI, so the agent inspects those, finds nothing, and concludes there
  # is nothing to do — leaving the conflict unresolved. The app already
  # detects the conflict when polling; surface it to the runner with a
  # concrete resolve-and-push instruction.
  defp append_conflict_directive(prompt, %{stage: :pr} = task) do
    prompt <> conflict_note(fetch_pull_request(task), task)
  end

  defp append_conflict_directive(prompt, _task), do: prompt

  defp fetch_pull_request(task) do
    project = task.project
    opts = [installation_id: installation_id(task)]

    case Client.get_pull_request(
           project.github_owner,
           project.github_repo,
           task.pr_number,
           opts
         ) do
      {:ok, pr} -> pr
      {:error, _reason} -> %{}
    end
  end

  @doc """
  Renders the merge-conflict directive appended to a PR-stage prompt.

  Returns an empty string when the PR is not in conflict (reusing
  `CheckPrStatus.merge_conflict?/1` so detection stays in one place), and
  otherwise an explicit instruction to merge the base branch, resolve the
  conflicts on the task branch, and push.
  """
  @spec conflict_note(map(), Task.t()) :: String.t()
  def conflict_note(pr, task) do
    if CheckPrStatus.merge_conflict?(pr) do
      base = get_in(pr, ["base", "ref"]) || "the base branch"

      "\n\n--- Merge Conflict ---\n" <>
        "This pull request (#{task.pr_url}) has merge conflicts with its " <>
        "base branch `#{base}` and cannot be merged as-is. Resolve them: " <>
        "fetch the latest `#{base}`, merge (or rebase) it into the working " <>
        "branch `camelot/task-#{task.id}`, resolve every conflict, verify " <>
        "the build and tests pass, and push so the PR becomes mergeable."
    else
      ""
    end
  end

  # Pin the working branch to a deterministic, task-scoped name so a
  # PR that the agent opens can be recovered from GitHub even when its
  # URL is missing from the final output (see TaskRunner fallback).
  defp append_branch_directive(prompt, task, "execution") do
    prompt <> branch_directive(task)
  end

  defp append_branch_directive(prompt, _task, _slug), do: prompt

  @doc """
  Renders the branch-stacking directive appended to an execution-stage
  prompt.

  Wording is chosen from the task's same-repo `:blocks` blockers that
  have already reached stage `:pr` (so they have a pushed branch to
  stack on):

    * none — the original single-branch instruction.
    * one — branch from that blocker's branch and target it as the PR
      base (stacked branches, see the moduledoc).
    * more than one — branch from the default branch and `git merge`
      each blocker branch in before starting.

  A cross-repo blocker never appears here: cross-repo links still gate
  dispatch and inject context (`related_context_block/1`), but there
  is no git branch to share across repositories.
  """
  @spec branch_directive(Task.t()) :: String.t()
  def branch_directive(task) do
    task
    |> stacked_blockers()
    |> branch_directive_for(task)
  end

  defp branch_directive_for([], task) do
    "\n\nWork on a git branch named exactly `camelot/task-#{task.id}` " <>
      "and open the pull request from that branch."
  end

  defp branch_directive_for([blocker], task) do
    "\n\nCreate a git branch named exactly `camelot/task-#{task.id}` " <>
      "from `camelot/task-#{blocker.id}` (already pushed) and open the " <>
      "pull request with `camelot/task-#{blocker.id}` as its base branch."
  end

  defp branch_directive_for(blockers, task) do
    names =
      blockers
      |> Enum.sort_by(& &1.id)
      |> Enum.map_join(", ", &"`camelot/task-#{&1.id}`")

    "\n\nCreate a git branch named exactly `camelot/task-#{task.id}` " <>
      "from the default branch, then `git merge --no-ff` each of " <>
      "#{names} into it in that order, committing each merge before " <>
      "starting the next. If two of those branches conflict with each " <>
      "other, resolve in favour of the branch merged later and note " <>
      "the resolution in the pull request description. Open the pull " <>
      "request against the default branch."
  end

  defp stacked_blockers(%{blockers: blockers, project: project}) when is_list(blockers) do
    Enum.filter(blockers, &(&1.stage == :pr and Resolver.same_repo?(project, &1.project)))
  end

  defp stacked_blockers(_task), do: []

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

  defp append_related_context(prompt, task) do
    case related_context_block(task) do
      "" -> prompt
      block -> prompt <> "\n\n" <> block
    end
  end

  @doc """
  Renders the "Related Tasks" block appended to every prompt: `:blocks`
  blockers (with a plan summary, PR link, and same-repo branch note),
  the parent task, subtasks and `:relates_to` cross-references. Empty
  string when the task has no links (built with no leading blank line,
  matching `attachments_block/1`), so nothing changes for an unlinked
  task; `append_related_context/2` adds the separating blank line only
  when there is something to show — this fires unconditionally in the
  `build/1` pipeline, unlike `attachments` which only reaches the
  prompt through a template variable, so it still applies context even
  when a project or user has overridden the template row.

  Requires `:blockers`, `[parent_link: :source_task]`, `:subtasks`,
  `:related_out_tasks` and `:related_in_tasks` to be loaded — see
  `Task.link_load/0`.
  """
  @spec related_context_block(Task.t()) :: String.t()
  def related_context_block(task) do
    lines = blocker_lines(task) ++ parent_lines(task) ++ subtask_lines(task) ++ related_lines(task)

    case lines do
      [] -> ""
      lines -> "--- Related Tasks ---\n" <> Enum.join(lines, "\n")
    end
  end

  defp blocker_lines(%{blockers: blockers} = task) when is_list(blockers) do
    Enum.map(blockers, &blocker_line(&1, task))
  end

  defp blocker_lines(_task), do: []

  defp blocker_line(blocker, task) do
    [
      "Depends on: #{title_and_project(blocker)} — stage: #{blocker.stage}",
      summary_line(blocker),
      pr_line(blocker, task),
      branch_line(blocker, task)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp parent_lines(task) do
    case Task.parent(task) do
      nil -> []
      parent -> ["Parent task: #{title_and_project(parent)}"]
    end
  end

  defp subtask_lines(%{subtasks: subtasks}) when is_list(subtasks) do
    Enum.map(subtasks, &"Subtask: #{title_and_project(&1)} — stage: #{&1.stage}")
  end

  defp subtask_lines(_task), do: []

  defp related_lines(task) do
    task
    |> Task.related_tasks()
    |> Enum.map(&"Related: #{title_and_project(&1)} — #{task_url(&1)}")
  end

  defp title_and_project(task), do: "\"#{task.title}\" [#{project_name(task)}]"

  defp project_name(%{project: %{name: name}}), do: name
  defp project_name(_task), do: "?"

  @related_summary_limit 300

  defp summary_line(%{full_plan: full_plan}) when is_binary(full_plan) and full_plan != "" do
    "  Summary: #{truncate(full_plan)}"
  end

  defp summary_line(%{plan: plan}) when is_binary(plan) and plan != "" do
    "  Summary: #{truncate(plan)}"
  end

  defp summary_line(_blocker), do: nil

  defp truncate(text) when byte_size(text) <= @related_summary_limit, do: text

  defp truncate(text) do
    String.slice(text, 0, @related_summary_limit) <> "…"
  end

  defp pr_line(%{pr_url: pr_url} = blocker, task) when is_binary(pr_url) and pr_url != "" do
    if Resolver.same_repo?(task.project, blocker.project) do
      "  PR: #{pr_url}"
    else
      "  PR: #{pr_url}   (different repo — no branch sharing)"
    end
  end

  defp pr_line(_blocker, _task), do: nil

  defp branch_line(%{stage: :pr} = blocker, task) do
    if Resolver.same_repo?(task.project, blocker.project) do
      "  Branch: camelot/task-#{blocker.id} (same repo — your base branch)"
    end
  end

  defp branch_line(_blocker, _task), do: nil

  # Verified route rather than the hand-built
  # `Endpoint.url() <> "/tasks/…"` the senders use: the path is checked
  # against the router at compile time, so renaming the route can't
  # silently ship a dead link into an agent's prompt.
  defp task_url(task), do: url(~p"/tasks/#{task.id}")

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
