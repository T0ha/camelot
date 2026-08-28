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

  Merge-conflict and CI-failure auto-fixes fire whenever the PR is in
  that state, regardless of who authored the latest commit. (A previous
  "suppress while a human pushed last" guard was removed: the agent's
  own commit identity varies by deployment — e.g. the GitHub App bot's
  `<login>@users.noreply.github.com` — and was misclassified as human,
  which wedged the auto-fix indefinitely. See git history to restore it
  with a robust identity check.)

  A `CHANGES_REQUESTED` verdict is subject to the same staleness guards
  as comments: only a reviewer's *current* verdict counts (GitHub keeps
  every review ever submitted, forever), and it must be newer than the
  last commit and unseen. Without those guards one undismissed review
  re-dispatched the agent every two minutes for eight hours.

  Those automatic re-dispatches are capped at a configurable number of
  consecutive attempts (see `max_auto_fix_attempts/0`, default 2), so a
  task the agent cannot fix stops looping and is left for human review.
  The cap can be raised, or set to `:infinity` to disable it entirely
  (never removed — the counter is still tracked). The counter resets on
  explicit human feedback (changes requested / new comments).
  """
  use Ash.Resource.Change

  alias Camelot.Board.Task
  alias Camelot.Github.Client
  alias Camelot.Github.Resolver

  require Logger

  # Default cap on consecutive automatic PR fix re-dispatches (merge
  # conflict / CI failure) before a task is left for human review.
  # Prevents an unfixable PR from re-queuing the agent every poll
  # forever. Overridable via `config :camelot, :pr_auto_fix,
  # max_attempts: <pos_integer | :infinity>`.
  @default_max_auto_fix_attempts 2

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
    auto_fixable? = merge_conflict?(pr) or ci_failing?(check_runs)
    maybe_log_auto_fix_cap(task, auto_fixable?)
    commit_date = last_commit_date(commits)
    seen_at = task.pr_comments_seen_at

    cond do
      auto_fixable? and auto_fix_available?(task) ->
        request_changes(task, comments, reviews, task.pr_auto_fix_attempts + 1)

      changes_requested?(reviews, commit_date, seen_at) ->
        request_changes(task, comments, reviews, 0)

      approved?(reviews) ->
        transition(task, :complete)

      new_comments?(comments, commit_date, seen_at) ->
        request_changes(task, comments, reviews, 0)

      true ->
        :ok
    end
  end

  @doc """
  The configured cap on consecutive automatic PR fix re-dispatches.

  Reads `config :camelot, :pr_auto_fix, max_attempts: …`, falling back to
  `#{@default_max_auto_fix_attempts}`. A positive integer caps the number
  of attempts; `:infinity` disables the cap (attempts are still tracked,
  the auto-fixer just never gives up).
  """
  @spec max_auto_fix_attempts() :: pos_integer() | :infinity
  def max_auto_fix_attempts do
    :camelot
    |> Application.get_env(:pr_auto_fix, [])
    |> Keyword.get(:max_attempts, @default_max_auto_fix_attempts)
  end

  @doc """
  Whether the task still has automatic PR fix attempts left.

  Merge-conflict and CI-failure auto-fixes re-dispatch the agent, capped
  at `max_auto_fix_attempts/0` consecutive attempts so a PR the agent
  cannot fix stops looping. The counter resets on explicit human
  feedback (changes requested / new comments).
  """
  @spec auto_fix_available?(Task.t()) :: boolean()
  def auto_fix_available?(%{pr_auto_fix_attempts: attempts}) do
    under_cap?(attempts, max_auto_fix_attempts())
  end

  def auto_fix_available?(_task), do: true

  @doc """
  Whether `attempts` is still below the given cap.

  `:infinity` is never exceeded, so the auto-fixer keeps retrying.
  """
  @spec under_cap?(integer(), pos_integer() | :infinity) :: boolean()
  def under_cap?(_attempts, :infinity), do: true
  def under_cap?(attempts, max) when is_integer(max), do: attempts < max

  defp maybe_log_auto_fix_cap(task, true), do: log_auto_fix_cap(task, auto_fix_available?(task))
  defp maybe_log_auto_fix_cap(_task, false), do: :ok

  defp log_auto_fix_cap(_task, true), do: :ok

  defp log_auto_fix_cap(task, false) do
    Logger.info(
      "Task #{task.id}: PR issue persists after " <>
        "#{max_auto_fix_attempts()} auto-fix attempts; " <>
        "leaving for human review"
    )
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

  @review_states ~w(APPROVED CHANGES_REQUESTED DISMISSED)

  @doc """
  Reduces a PR's review list to each reviewer's current verdict.

  GitHub returns every review ever submitted, forever, so scanning the
  raw list reports a verdict the reviewer has already superseded. Only
  the latest state-bearing review per reviewer counts; `COMMENTED` and
  `PENDING` reviews carry no verdict and never supersede one.
  """
  @spec latest_reviews([map()]) :: [map()]
  def latest_reviews(reviews) do
    reviews
    |> Enum.filter(&(&1["state"] in @review_states))
    |> Enum.group_by(&reviewer_login/1)
    |> Enum.map(fn {_login, submitted} ->
      Enum.max_by(submitted, &review_date/1)
    end)
  end

  @doc """
  True if a reviewer's current verdict is an unaddressed
  `CHANGES_REQUESTED`.

  A review never expires, so a bare state check re-fires on every poll
  forever. The guards the comment path uses apply here too: the verdict
  must be newer than the last commit — pushing a fix addresses it — and
  unseen since the last dispatch.
  """
  @spec changes_requested?([map()], String.t() | nil, DateTime.t() | nil) ::
          boolean()
  def changes_requested?(reviews, last_commit_date, seen_at) do
    reviews
    |> latest_reviews()
    |> Enum.any?(fn review ->
      review["state"] == "CHANGES_REQUESTED" and
        unaddressed?(review_date(review), last_commit_date, seen_at)
    end)
  end

  @doc """
  True if a reviewer's current verdict is `APPROVED`.

  Checked against current verdicts, so a reviewer who requested changes
  and later approved completes the task instead of being read as still
  blocking it.
  """
  @spec approved?([map()]) :: boolean()
  def approved?(reviews) do
    reviews
    |> latest_reviews()
    |> Enum.any?(&(&1["state"] == "APPROVED"))
  end

  defp reviewer_login(%{"user" => %{"login" => login}}), do: login
  defp reviewer_login(_review), do: nil

  defp review_date(%{"submitted_at" => submitted_at}), do: submitted_at
  defp review_date(_review), do: nil

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
      unaddressed?(comment["created_at"], last_commit_date, seen_at)
    end)
  end

  # Feedback is worth acting on only when the agent has not already
  # answered it: newer than the last commit, and past the seen marker.
  defp unaddressed?(created, last_commit_date, seen_at) do
    newer_than_commit?(created, last_commit_date) and unseen?(created, seen_at)
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

  @doc """
  The marker to record as "feedback seen up to here".

  Spans both feedback surfaces — comments and review verdicts — so a
  body-less `CHANGES_REQUESTED` review is marked seen too. Marking only
  the latest comment would leave a newer review permanently unseen, and
  re-dispatch it on every poll.
  """
  @spec feedback_seen_at([map()], [map()]) :: DateTime.t()
  def feedback_seen_at(comments, reviews) do
    dates =
      Enum.map(comments, & &1["created_at"]) ++
        Enum.map(reviews, &review_date/1)

    dates
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> nil end)
    |> parse_seen_at()
  end

  defp parse_seen_at(nil), do: DateTime.utc_now()
  defp parse_seen_at(iso), do: parse_github_datetime(iso)

  defp request_changes(task, comments, reviews, attempts) do
    seen_at = feedback_seen_at(comments, reviews)

    case Ash.update(
           task,
           %{pr_comments_seen_at: seen_at, pr_auto_fix_attempts: attempts},
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
