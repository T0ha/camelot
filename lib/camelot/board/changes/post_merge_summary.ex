defmodule Camelot.Board.Changes.PostMergeSummary do
  @moduledoc """
  Closes the loop on the GitHub issue a task was imported from once
  its pull request lands — called by
  `Camelot.Board.Changes.CheckPrStatus` right before it moves the task
  to `:done` (merged) or `:cancelled` (closed without merge), with the
  PR data that poll already fetched.

    * **Merged** — one summary comment (PR link, diff stats, commits,
      the PR body's own `## Summary` section, the approved plan), then
      the `camelot:done` label, `camelot:approved` /
      `camelot:invalid-config` removed, and the issue closed if open.
    * **Closed without merge** — a short note; the issue stays open.

  Idempotent: `merge_summary_posted_at` is the primary guard, and a
  search for the hidden marker comment covers a crash between posting
  the comment and recording it. Label and close calls are best effort —
  the comment is the record that matters.
  """

  alias Camelot.Board.Changes.CheckPrStatus
  alias Camelot.Board.Task
  alias Camelot.Github.Client
  alias Camelot.Github.PullRequestApi

  require Logger

  @done_label "camelot:done"
  @stale_labels ["camelot:approved", "camelot:invalid-config"]
  @max_commits 50
  @max_plan_chars 10_000

  @typedoc """
  What the summary is built from: the PR, its commits and reviews (as
  `CheckPrStatus` fetched them), and the issue and its comments.
  """
  @type github :: %{
          pr: map(),
          commits: [map()],
          reviews: [map()],
          issue: map(),
          comments: [map()]
        }

  @type outcome :: :merged | :closed
  @type result :: :ok | :skipped | :already_posted | {:error, term()}

  @doc """
  Fetches the issue and its comments, then `publish/3`es. Never
  raises; a GitHub failure is logged and returned.
  """
  @spec post(Task.t(), outcome(), map(), [map()], [map()]) :: result()
  def post(%Task{issue_number: nil}, _outcome, _pr, _commits, _reviews), do: :skipped
  def post(%Task{merge_summary_posted_at: %DateTime{}}, _outcome, _pr, _commits, _reviews), do: :already_posted

  def post(task, outcome, pr, commits, reviews) do
    owner = task.project.github_owner
    repo = task.project.github_repo
    opts = [installation_id: CheckPrStatus.installation_id(task)]

    with {:ok, issue} <- Client.get_issue(owner, repo, task.issue_number, opts),
         {:ok, comments} <- Client.list_issue_comments(owner, repo, task.issue_number, opts) do
      publish(task, outcome, %{pr: pr, commits: commits, reviews: reviews, issue: issue, comments: comments})
    else
      {:error, reason} -> log_failure(task, reason)
    end
  end

  @doc "Posts the summary for `outcome` from already-fetched `github` data."
  @spec publish(Task.t(), outcome(), github()) :: result()
  def publish(%Task{issue_number: nil}, _outcome, _github), do: :skipped
  def publish(%Task{merge_summary_posted_at: %DateTime{}}, _outcome, _github), do: :already_posted

  def publish(task, outcome, github) do
    github.comments
    |> Enum.any?(&marker_comment?(&1, task))
    |> publish_once(task, outcome, github)
  end

  # A marker comment without a recorded timestamp means the last poll
  # crashed between posting and recording: record it, post nothing.
  defp publish_once(true, task, _outcome, _github) do
    mark_posted(task)
    :already_posted
  end

  defp publish_once(false, task, outcome, github), do: post_summary(task, outcome, github)

  defp post_summary(task, outcome, github) do
    body = summary_body(task, outcome, github)

    case api().create_issue_comment(owner(task), repo(task), task.issue_number, body, opts(task)) do
      {:ok, _comment} ->
        mark_posted(task)
        finish_issue(task, outcome, github.issue)
        :ok

      {:error, reason} ->
        log_failure(task, reason)
    end
  end

  defp marker_comment?(comment, task), do: String.contains?(comment["body"] || "", marker(task))

  defp marker(task), do: "<!-- camelot:merge-summary task=#{task.id} -->"

  defp mark_posted(task) do
    case Ash.update(task, %{merge_summary_posted_at: DateTime.utc_now()}, action: :mark_merge_summary_posted) do
      {:ok, _task} -> :ok
      {:error, error} -> Logger.warning("Failed to record merge summary for task #{task.id}: #{inspect(error)}")
    end
  end

  defp finish_issue(_task, :closed, _issue), do: :ok

  defp finish_issue(task, :merged, issue) do
    labels = label_names(issue)

    best_effort(task, api().add_issue_labels(owner(task), repo(task), task.issue_number, [@done_label], opts(task)))

    @stale_labels
    |> Enum.filter(&(&1 in labels))
    |> Enum.each(fn label ->
      best_effort(task, api().remove_issue_label(owner(task), repo(task), task.issue_number, label, opts(task)))
    end)

    close_if_open(task, issue["state"])
  end

  defp close_if_open(task, "open") do
    best_effort(task, api().close_issue(owner(task), repo(task), task.issue_number, opts(task)))
  end

  defp close_if_open(_task, _state), do: :ok

  defp best_effort(_task, {:ok, _result}), do: :ok
  defp best_effort(task, {:error, reason}), do: log_failure(task, reason)

  defp label_names(issue), do: Enum.map(issue["labels"] || [], & &1["name"])

  @doc "The summary comment for `outcome`."
  @spec summary_body(Task.t(), outcome(), github()) :: String.t()
  def summary_body(task, :closed, %{pr: pr}) do
    """
    #{marker(task)}
    Pull request #{pr_link(task, pr)} was closed without merge; the \
    Camelot task was cancelled. Re-open the PR, or re-attach the issue, \
    to continue.
    """
  end

  def summary_body(task, :merged, %{pr: pr} = github) do
    [
      marker(task),
      "## Merged: #{pr_link(task, pr)}",
      merged_line(pr),
      stats_line(pr),
      approvals_line(github.reviews),
      pr_summary(pr["body"]),
      commits_section(github.commits),
      plan_section(task)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp pr_link(task, pr) do
    "[##{pr["number"] || task.pr_number}#{title_suffix(pr["title"])}](#{pr["html_url"] || task.pr_url})"
  end

  defp title_suffix(nil), do: ""
  defp title_suffix(title), do: " #{title}"

  defp merged_line(%{"merged_by" => %{"login" => login}, "merged_at" => at}), do: "Merged by @#{login} at #{at}."
  defp merged_line(_pr), do: nil

  defp stats_line(%{"additions" => adds, "deletions" => dels, "changed_files" => files}) do
    "**+#{adds} / -#{dels}** across #{files} files."
  end

  defp stats_line(_pr), do: nil

  defp approvals_line(reviews) do
    reviews
    |> CheckPrStatus.latest_reviews()
    |> Enum.filter(&(&1["state"] == "APPROVED"))
    |> Enum.map(&get_in(&1, ["user", "login"]))
    |> Enum.reject(&is_nil/1)
    |> approvals()
  end

  defp approvals([]), do: nil
  defp approvals(logins), do: "Approved by #{Enum.map_join(logins, ", ", &"@#{&1}")}."

  @doc """
  The `## Summary` section of a PR body (up to the next `##` heading),
  or `nil` when the body has none.
  """
  @spec pr_summary(String.t() | nil) :: String.t() | nil
  def pr_summary(nil), do: nil

  def pr_summary(body) do
    case Regex.run(~r/^##\s+Summary\s*$(.*?)(?=^##\s|\z)/ims, body, capture: :all_but_first) do
      [section] -> section |> String.trim() |> summary_section()
      nil -> nil
    end
  end

  defp summary_section(""), do: nil
  defp summary_section(section), do: "### Summary\n\n" <> section

  defp commits_section([]), do: nil

  defp commits_section(commits) do
    lines =
      commits
      |> Enum.take(@max_commits)
      |> Enum.map_join("\n", &commit_line/1)

    "### Commits\n\n" <> lines <> more_commits(length(commits))
  end

  defp more_commits(count) when count > @max_commits, do: "\n- … and #{count - @max_commits} more"
  defp more_commits(_count), do: ""

  defp commit_line(commit) do
    sha = String.slice(commit["sha"] || "", 0, 7)
    subject = commit |> get_in(["commit", "message"]) |> first_line()
    "- `#{sha}` #{subject}"
  end

  defp first_line(nil), do: ""
  defp first_line(message), do: message |> String.split("\n", parts: 2) |> hd()

  defp plan_section(%Task{plan: nil}), do: nil

  defp plan_section(task) do
    """
    <details><summary>Executed plan</summary>

    #{String.slice(task.plan, 0, @max_plan_chars)}

    </details>
    """
  end

  defp log_failure(task, reason) do
    Logger.warning("Merge summary for task #{task.id} (issue ##{task.issue_number}) failed: #{inspect(reason)}")

    {:error, reason}
  end

  defp api, do: PullRequestApi.impl()
  defp owner(task), do: task.project.github_owner
  defp repo(task), do: task.project.github_repo
  defp opts(task), do: [installation_id: CheckPrStatus.installation_id(task)]
end
