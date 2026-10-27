defmodule Camelot.Board.IssueComments do
  @moduledoc """
  Reads a task's GitHub issue comments the way the issue workflow
  trusts them, shared by `Camelot.Board.Changes.CheckIssuePlan` (plan
  review), `Camelot.Board.Changes.CheckPrStatus` (while the PR is open)
  and `Camelot.Board.PromptBuilder`.

  Every comment gets an `"acted_at"`: the moment Camelot may act on it.

    * A project member's comment acts at its own `created_at`.
    * A stranger's comment acts at the `created_at` of the project
      owner's 👍 vouching for it (`Camelot.Github.IssueTrust`), and an
      edit after that 👍 voids it.
    * Any other comment has `"acted_at" => nil` and is ignored.

  `acted_at` is compared to `issue_comments_seen_at` rather than
  passing `since:` to GitHub, because GitHub's `since` filters on
  `updated_at` and a reaction does not bump it: an owner vouching for a
  stranger's comment after it was first seen would never be noticed.
  """

  alias Camelot.Board.Changes.CheckPrStatus
  alias Camelot.Board.Task
  alias Camelot.Github.Client
  alias Camelot.Github.IssueTrust

  @typedoc "A GitHub issue comment, as the REST API sends it."
  @type comment :: %{optional(String.t()) => term()}

  @doc """
  Fetches the PR-phase window (`window/2`) of the task's issue
  comments, each annotated with `"acted_at"` (`annotate/3`).

  Fetches reactions only for strangers' comments; a failed reaction
  fetch counts as no reactions, so that comment just waits for the next
  poll. Makes no call at all when the task has no issue, or when the
  "issue" is the task's own PR (its comments are already read as PR
  comments).

  `task` must be loaded with `:project` and
  `creator: [:github_installations]`.
  """
  @spec fetch(Task.t()) :: {:ok, [comment()]} | {:error, term()}
  def fetch(%{issue_number: nil}), do: {:ok, []}
  def fetch(%{issue_number: number, pr_number: number}), do: {:ok, []}

  def fetch(task) do
    owner = task.project.github_owner
    repo = task.project.github_repo
    opts = [installation_id: CheckPrStatus.installation_id(task)]

    with {:ok, comments} <- Client.list_issue_comments(owner, repo, task.issue_number, opts) do
      window = window(task, comments)
      ids = stranger_comment_ids(task, window)

      {:ok, annotate(task, window, reactions(owner, repo, ids, opts))}
    end
  end

  @doc """
  The comments that count once the plan is settled: not Camelot's own
  bot comments (plan, approval and merge-summary posts), posted after
  the plan comment and after the task was created, sorted by id
  (GitHub comment ids increase monotonically).
  """
  @spec window(Task.t(), [comment()]) :: [comment()]
  def window(task, comments) do
    comments
    |> Enum.reject(&CheckPrStatus.bot_authored?/1)
    |> Enum.filter(&(&1["id"] > (task.plan_comment_id || 0) and unseen?(&1["created_at"], task.inserted_at)))
    |> Enum.sort_by(& &1["id"])
  end

  @doc "Ids of `comments` written by someone who is not a project member."
  @spec stranger_comment_ids(Task.t(), [comment()]) :: [integer()]
  def stranger_comment_ids(task, comments) do
    comments
    |> Enum.reject(&IssueTrust.trusted?(IssueTrust.actor_id(&1), task.project_id))
    |> Enum.map(& &1["id"])
  end

  @doc """
  Fetches the reactions on each comment in `comment_ids`, by id. Best
  effort: a failed fetch counts as no reactions.
  """
  @spec reactions(String.t(), String.t(), [integer()], keyword()) ::
          %{optional(integer()) => [map()]}
  def reactions(owner, repo, comment_ids, opts) do
    Map.new(comment_ids, fn id ->
      case Client.list_comment_reactions(owner, repo, id, opts) do
        {:ok, reactions} -> {id, reactions}
        {:error, _reason} -> {id, []}
      end
    end)
  end

  @doc """
  Puts `"acted_at"` (`acted_at/3`) on each comment, reading a comment's
  reactions from `reactions_by_id`.
  """
  @spec annotate(Task.t(), [comment()], %{optional(integer()) => [map()]}) ::
          [comment()]
  def annotate(task, comments, reactions_by_id) do
    Enum.map(comments, fn comment ->
      reactions = Map.get(reactions_by_id, comment["id"], [])
      Map.put(comment, "acted_at", acted_at(comment, reactions, task.project_id))
    end)
  end

  @doc """
  When Camelot may act on `comment`: a member's `created_at`, the owner
  👍's `created_at` for a stranger, or `nil` when it must be ignored.
  """
  @spec acted_at(comment(), [map()], Ash.UUID.t()) :: String.t() | nil
  def acted_at(comment, reactions, project_id) do
    comment
    |> IssueTrust.actor_id()
    |> IssueTrust.trusted?(project_id)
    |> trusted_acted_at(comment, reactions, project_id)
  end

  defp trusted_acted_at(true, comment, _reactions, _project_id), do: comment["created_at"]

  defp trusted_acted_at(false, comment, reactions, project_id) do
    comment
    |> IssueTrust.owner_approval(reactions, project_id)
    |> approval_time()
  end

  defp approval_time(nil), do: nil
  defp approval_time(approval), do: approval["created_at"]

  @doc """
  Whether a GitHub ISO 8601 time is after `seen_at`. Everything is
  unseen without a marker; a missing or malformed time never is.
  """
  @spec unseen?(String.t() | nil, DateTime.t() | nil) :: boolean()
  def unseen?(_iso, nil), do: true
  def unseen?(nil, _seen_at), do: false

  def unseen?(iso, seen_at) do
    case DateTime.from_iso8601(iso) do
      {:ok, time, _offset} -> DateTime.after?(time, seen_at)
      {:error, _reason} -> false
    end
  end

  @doc "The accepted comments (non-nil `acted_at`) acted on after `seen_at`."
  @spec new_since([comment()], DateTime.t() | nil) :: [comment()]
  def new_since(comments, seen_at) do
    Enum.filter(comments, &(&1["acted_at"] && unseen?(&1["acted_at"], seen_at)))
  end

  @doc """
  The `issue_comments_seen_at` to record once `comments` were handed to
  the agent: their latest `acted_at`. A GitHub timestamp rather than
  `DateTime.utc_now/0`, so a comment posted mid-poll is not skipped.
  `comments` must be non-empty and accepted (see `new_since/2`).
  """
  @spec seen_marker([comment(), ...]) :: DateTime.t()
  def seen_marker(comments) do
    {:ok, time, _offset} =
      comments
      |> Enum.map(& &1["acted_at"])
      |> Enum.max()
      |> DateTime.from_iso8601()

    time
  end
end
