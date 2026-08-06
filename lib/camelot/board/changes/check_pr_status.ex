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

  "Comments" covers three GitHub surfaces: top-level issue comments,
  inline review comments on the diff (`pulls/{n}/comments`), and the
  body of a `COMMENTED` review — a reviewer who leaves inline notes or
  a plain "Comment" review (not "Request changes") is acted on too.

  Merge-conflict and CI-failure auto-fixes are suppressed while a human
  authored the latest commit: a reviewer hand-fixing the branch during
  review is re-verified, not fought. The agent's own commits (authored
  by the Camelot agent) never count as human activity.
  """
  use Ash.Resource.Change

  alias Camelot.Board.Task
  alias Camelot.Github.Client
  alias Camelot.Github.Resolver

  require Logger

  @impl true
  @spec change(
          Ash.Changeset.t(),
          keyword(),
          Ash.Resource.Change.context()
        ) :: Ash.Changeset.t()
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, task ->
      task = Ash.load!(task, [:project, creator: [:github_installations]], authorize?: false)
      check_and_transition(task)
      {:ok, task}
    end)
  end

  defp check_and_transition(task) do
    project = task.project
    owner = project.github_owner
    repo = project.github_repo
    pr = task.pr_number
    opts = [installation_id: installation_id(task)]

    with {:ok, pr_data} <-
           Client.get_pull_request(owner, repo, pr, opts),
         {:ok, reviews} <-
           Client.list_pull_request_reviews(owner, repo, pr, opts),
         {:ok, comments} <-
           Client.list_pull_request_comments(owner, repo, pr, opts),
         {:ok, commits} <-
           Client.list_pull_request_commits(owner, repo, pr, opts),
         {:ok, check_runs} <-
           fetch_check_runs(owner, repo, pr_data, opts) do
      review_comments = fetch_review_comments(owner, repo, pr, opts)
      feedback = merge_review_feedback(comments, review_comments, reviews)
      apply_pr_state(task, pr_data, reviews, feedback, commits, check_runs)
    else
      {:error, reason} ->
        Logger.warning(
          "Failed to check PR for task #{task.id}: " <>
            "#{inspect(reason)}"
        )
    end
  end

  @doc """
  Resolves the GitHub App installation id from the task
  creator's connected installation, if any.
  """
  @spec installation_id(Task.t()) :: integer() | nil
  def installation_id(%{creator: %{github_installations: installations}} = task) do
    Resolver.installation_id(installations, github_owner(task))
  end

  def installation_id(_task), do: nil

  defp github_owner(%{project: %{github_owner: owner}}), do: owner
  defp github_owner(_task), do: nil

  defp fetch_check_runs(owner, repo, pr_data, opts) do
    case get_in(pr_data, ["head", "sha"]) do
      nil ->
        {:ok, []}

      sha ->
        owner
        |> Client.list_check_runs(repo, sha, opts)
        |> best_effort_check_runs()
    end
  end

  @doc """
  Coerces a check-runs fetch into an always-`{:ok, runs}` result.

  CI status only *enriches* PR reconciliation (a failing run queues an
  auto-fix); it must never block it. A missing **Checks** permission on
  the App installation 403s the check-runs endpoint — degrade that to
  "no checks" so merge-conflict, review, and comment handling still run,
  mirroring `fetch_review_comments/4`. The trade-off is intentional: CI
  failures simply go undetected until the permission is granted.
  """
  @spec best_effort_check_runs({:ok, [map()]} | {:error, term()}) ::
          {:ok, [map()]}
  def best_effort_check_runs({:ok, runs}), do: {:ok, runs}

  def best_effort_check_runs({:error, reason}) do
    Logger.warning(
      "check-runs unavailable (#{inspect(reason)}); treating as " <>
        "no checks"
    )

    {:ok, []}
  end

  # Best-effort: inline review comments enrich detection but must never
  # block the core transition flow, so a failure degrades to no comments.
  defp fetch_review_comments(owner, repo, pr, opts) do
    case Client.list_pull_request_review_comments(owner, repo, pr, opts) do
      {:ok, review_comments} -> review_comments
      {:error, _reason} -> []
    end
  end

  @doc """
  Merges the three reviewer-feedback surfaces into one comment list.

  GitHub splits reviewer feedback across top-level issue comments,
  inline review comments on the diff, and review bodies. Inline
  comments already carry `created_at`; a review body is normalised to
  `created_at` from its `submitted_at`. Empty review bodies are dropped
  — an inline-only review has an empty body, and its content lives in
  the review comments instead.
  """
  @spec merge_review_feedback([map()], [map()], [map()]) :: [map()]
  def merge_review_feedback(comments, review_comments, reviews) do
    comments ++ review_comments ++ review_body_comments(reviews)
  end

  defp review_body_comments(reviews) do
    reviews
    |> Enum.filter(&review_has_body?/1)
    |> Enum.map(fn review ->
      %{
        "created_at" => review["submitted_at"],
        "user" => review["user"],
        "body" => review["body"]
      }
    end)
  end

  defp review_has_body?(%{"body" => ""}), do: false
  defp review_has_body?(%{"body" => nil}), do: false
  defp review_has_body?(%{"body" => _body}), do: true
  defp review_has_body?(_review), do: false

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
    # A human hand-fixing the branch during review is re-verified, not
    # fought: suppress the CI/merge auto-fix while a human authored the
    # latest commit. Explicit feedback (changes requested / comments)
    # still wakes the agent regardless of who pushed last.
    human_pushed_last? = latest_commit_human?(commits)

    cond do
      not human_pushed_last? and merge_conflict?(pr) ->
        transition_with_seen_at(task, comments)

      not human_pushed_last? and ci_failing?(check_runs) ->
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

  # The Camelot agent authors commits under these git identities; a
  # commit touched by either (as author or committer) is agent work,
  # never a human hand-fix.
  @agent_emails ~w(camelot-agent@anthropic.com noreply@anthropic.com)

  @doc """
  True if the latest commit on the PR was authored by a human.

  Used to suppress CI/merge auto-fixes while a reviewer is hand-fixing
  the branch. An empty commit list is not human, so the agent's own
  self-heal path is preserved when no commits have landed yet.
  """
  @spec latest_commit_human?([map()]) :: boolean()
  def latest_commit_human?(commits) do
    case List.last(commits) do
      nil -> false
      commit -> human_commit?(commit)
    end
  end

  defp human_commit?(commit) do
    author = get_in(commit, ["commit", "author", "email"])
    committer = get_in(commit, ["commit", "committer", "email"])

    author not in @agent_emails and committer not in @agent_emails
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
