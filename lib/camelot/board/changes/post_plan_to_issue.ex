defmodule Camelot.Board.Changes.PostPlanToIssue do
  @moduledoc """
  Writes a task's plan back to the GitHub issue it was imported from,
  so the plan can be reviewed — and approved — without leaving GitHub.

  Run by `Camelot.Board.Workers.PostToIssue` on the `:github` queue
  after `:submit_plan` (and, for `post_ui_approval/1`, after a UI
  `:approve_plan`); see `Camelot.Board.Notifiers.EnqueueIssuePost`.

  Every plan, including a re-plan, is posted as a **new** comment
  rather than an edit: the old comment's 👍s and replies belong to the
  old plan, and `plan_comment_id` moving to the new comment is what
  makes `Camelot.Board.Changes.CheckIssuePlan` ignore them.
  """

  alias Camelot.Board.Changes.CheckPrStatus
  alias Camelot.Board.Task
  alias Camelot.Github.PullRequestApi

  require Logger

  # GitHub caps a comment body at 65,536 characters.
  @max_plan_chars 60_000

  @doc "What a task needs loaded for the functions here."
  @spec load() :: keyword()
  def load, do: [:project, creator: [:github_installations]]

  @doc """
  Posts the plan as a new issue comment and records it as the task's
  `plan_comment_id` (via `:record_plan_comment`, which emits the
  `plan_posted` telemetry event).

  `:skipped` for a task with no linked issue; `{:error, reason}` when
  GitHub refused, so the worker retries.
  """
  @spec post_plan(Task.t()) :: :ok | :skipped | {:error, term()}
  def post_plan(%Task{issue_number: nil}), do: :skipped

  def post_plan(task) do
    with {:ok, %{"id" => comment_id}} <- comment(task, plan_comment_body(task, CamelotWeb.Endpoint.url())),
         {:ok, updated} <- Ash.update(task, %{plan_comment_id: comment_id}, action: :record_plan_comment) do
      broadcast(updated)
      :ok
    else
      {:ok, unexpected} ->
        log_failure(task, {:unexpected_response, unexpected})

      {:error, reason} ->
        log_failure(task, reason)
    end
  end

  @doc """
  Tells the issue its plan was approved from the Camelot UI, so an
  issue-only reviewer is not left waiting on a plan that is already
  executing.
  """
  @spec post_ui_approval(Task.t()) :: :ok | :skipped | {:error, term()}
  def post_ui_approval(%Task{issue_number: nil}), do: :skipped

  def post_ui_approval(task) do
    body = "<!-- camelot:plan-approved task=#{task.id} -->\nPlan approved in Camelot; execution has started."

    case comment(task, body) do
      {:ok, _comment} -> :ok
      {:error, reason} -> log_failure(task, reason)
    end
  end

  @doc """
  The plan comment: a hidden marker, the plan (the full plan document
  when the agent wrote one), and how to approve or request changes.

  A plan longer than GitHub can hold is truncated, with a link to the
  task's plan page under `base_url`.
  """
  @spec plan_comment_body(Task.t(), String.t()) :: String.t()
  def plan_comment_body(task, base_url) do
    """
    <!-- camelot:plan task=#{task.id} -->
    ## Camelot plan

    #{plan_text(task, base_url)}

    ---
    **To approve**, comment `/approve` or react 👍 to this comment. \
    **To request changes**, reply with a comment describing them — \
    Camelot will revise the plan. Only project members are listened to.
    """
  end

  defp plan_text(task, base_url) do
    plan = task.full_plan || task.plan || ""

    plan
    |> String.length()
    |> Kernel.>(@max_plan_chars)
    |> truncate_plan(plan, task, base_url)
  end

  defp truncate_plan(false, plan, _task, _base_url), do: plan

  defp truncate_plan(true, plan, task, base_url) do
    String.slice(plan, 0, @max_plan_chars) <>
      "\n\n… _(truncated — [read the full plan](#{base_url}/tasks/#{task.id}/plan))_"
  end

  defp comment(task, body) do
    PullRequestApi.impl().create_issue_comment(
      task.project.github_owner,
      task.project.github_repo,
      task.issue_number,
      body,
      installation_id: CheckPrStatus.installation_id(task)
    )
  end

  defp log_failure(task, reason) do
    Logger.warning("Could not post to issue ##{task.issue_number} for task #{task.id}: #{inspect(reason)}")

    {:error, reason}
  end

  defp broadcast(task) do
    Phoenix.PubSub.broadcast(Camelot.PubSub, "board", {:task_updated, task})
    Phoenix.PubSub.broadcast(Camelot.PubSub, "task:#{task.id}", {:task_updated, task})
  end
end
