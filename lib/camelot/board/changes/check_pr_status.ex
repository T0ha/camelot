defmodule Camelot.Board.Changes.CheckPrStatus do
  @moduledoc """
  Ash change that checks GitHub PR status and transitions
  the task accordingly.

  Transitions:
  - merged → done (via complete)
  - closed → cancelled (via cancel)
  - merge conflict → queued for agent fix (via request_pr_changes)
  - failing CI checks → queued for agent fix (via request_pr_changes)
  - changes_requested → queued for agent fix (via request_pr_changes)
  - new comments after last commit → queued for agent fix
  - approved → done (via complete)
  """
  use Ash.Resource.Change

  alias Camelot.Github.Client

  require Logger

  @impl true
  @spec change(
          Ash.Changeset.t(),
          keyword(),
          Ash.Resource.Change.context()
        ) :: Ash.Changeset.t()
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, task ->
      task = Ash.load!(task, :project)
      check_and_transition(task)
      {:ok, task}
    end)
  end

  defp check_and_transition(task) do
    project = task.project
    owner = project.github_owner
    repo = project.github_repo
    pr = task.pr_number

    with {:ok, pr_data} <-
           Client.get_pull_request(owner, repo, pr),
         {:ok, reviews} <-
           Client.list_pull_request_reviews(owner, repo, pr),
         {:ok, comments} <-
           Client.list_pull_request_comments(owner, repo, pr),
         {:ok, commits} <-
           Client.list_pull_request_commits(owner, repo, pr),
         {:ok, check_runs} <-
           fetch_check_runs(owner, repo, pr_data) do
      apply_pr_state(task, pr_data, reviews, comments, commits, check_runs)
    else
      {:error, reason} ->
        Logger.warning(
          "Failed to check PR for task #{task.id}: " <>
            "#{inspect(reason)}"
        )
    end
  end

  defp fetch_check_runs(owner, repo, pr_data) do
    case get_in(pr_data, ["head", "sha"]) do
      nil -> {:ok, []}
      sha -> Client.list_check_runs(owner, repo, sha)
    end
  end

  defp apply_pr_state(task, pr, reviews, comments, commits, check_runs) do
    cond do
      pr["merged"] == true ->
        transition(task, :complete)

      pr["state"] == "closed" ->
        transition(task, :cancel)

      task.state == :waiting_for_input ->
        apply_waiting_for_input(task, pr, reviews, comments, commits, check_runs)

      true ->
        :ok
    end
  end

  defp apply_waiting_for_input(task, pr, reviews, comments, commits, check_runs) do
    cond do
      merge_conflict?(pr) ->
        transition_with_seen_at(task, comments)

      ci_failing?(check_runs) ->
        transition_with_seen_at(task, comments)

      has_review_state?(reviews, "CHANGES_REQUESTED") ->
        transition_with_seen_at(task, comments)

      has_review_state?(reviews, "APPROVED") ->
        transition(task, :complete)

      has_new_comments?(task, comments, commits) ->
        transition_with_seen_at(task, comments)

      true ->
        :ok
    end
  end

  @doc """
  True if GitHub reports an unresolved merge conflict.

  `mergeable` is `nil` while GitHub is still computing the merge —
  must not trigger. `mergeable_state == "blocked"` is a branch
  protection gate, not a git conflict, so only `"dirty"` counts.
  """
  @spec merge_conflict?(map()) :: boolean()
  def merge_conflict?(pr) do
    pr["mergeable"] == false and pr["mergeable_state"] == "dirty"
  end

  @failing_conclusions ~w(failure timed_out action_required cancelled)

  @doc """
  True if any completed check run failed.

  Only `status == "completed"` runs are considered — `in_progress`/
  `queued` runs have `conclusion == nil` and must not trigger, since
  CI still running isn't CI failing. `cancelled` is included because a
  cancelled run at a fixed head sha never reruns on its own.
  """
  @spec ci_failing?([map()]) :: boolean()
  def ci_failing?(check_runs) do
    Enum.any?(check_runs, fn run ->
      run["status"] == "completed" and
        run["conclusion"] in @failing_conclusions
    end)
  end

  defp has_review_state?(reviews, state) do
    Enum.any?(reviews, &(&1["state"] == state))
  end

  defp has_new_comments?(task, comments, commits) do
    new_comments?(comments, last_commit_date(commits), task.pr_comments_seen_at)
  end

  @doc """
  True if any comment is newer than the last commit AND unseen.

  Deliberately does NOT filter by author. Runners open PRs with the
  user's own GitHub token, so the PR author and the human reviewer are
  the same account — an author-based filter would silently drop the
  reviewer's feedback (which is exactly the comment we must react to).
  Nothing in the app posts PR comments, so there is no bot chatter to
  exclude; re-trigger loops are prevented by `pr_comments_seen_at` and
  the newer-than-last-commit guard.
  """
  @spec new_comments?([map()], String.t() | nil, DateTime.t() | nil) :: boolean()
  def new_comments?(comments, last_commit_date, seen_at) do
    Enum.any?(comments, fn comment ->
      created = comment["created_at"]
      newer_than_commit?(created, last_commit_date) and unseen?(created, seen_at)
    end)
  end

  defp newer_than_commit?(_created, nil), do: true
  defp newer_than_commit?(nil, _commit_date), do: false
  defp newer_than_commit?(created, commit_date), do: created > commit_date

  defp unseen?(_created, nil), do: true
  defp unseen?(nil, _seen_at), do: false
  defp unseen?(created, seen_at), do: created > DateTime.to_iso8601(seen_at)

  defp last_commit_date(commits) do
    case List.last(commits) do
      nil -> nil
      commit -> get_in(commit, ["commit", "committer", "date"])
    end
  end

  defp latest_comment_date(comments) do
    comments
    |> Enum.map(& &1["created_at"])
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> nil end)
  end

  defp transition_with_seen_at(task, comments) do
    seen_at =
      case latest_comment_date(comments) do
        nil -> DateTime.utc_now()
        iso -> parse_github_datetime(iso)
      end

    case Ash.update(
           task,
           %{pr_comments_seen_at: seen_at},
           action: :request_pr_changes
         ) do
      {:ok, updated} ->
        broadcast(updated)
        Logger.info("Task #{task.id} → request_pr_changes")

      {:error, error} ->
        Logger.warning(
          "Failed transition request_pr_changes for " <>
            "task #{task.id}: #{inspect(error)}"
        )
    end
  end

  defp parse_github_datetime(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _offset} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp transition(task, action) do
    case Ash.update(task, %{}, action: action) do
      {:ok, updated} ->
        broadcast(updated)
        Logger.info("Task #{task.id} → #{action}")

      {:error, error} ->
        Logger.warning(
          "Failed transition #{action} for " <>
            "task #{task.id}: #{inspect(error)}"
        )
    end
  end

  defp broadcast(task) do
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
end
