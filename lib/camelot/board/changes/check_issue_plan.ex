defmodule Camelot.Board.Changes.CheckIssuePlan do
  @moduledoc """
  Ash change behind the `:check_issue_plan` AshOban trigger: polls the
  GitHub issue of a task whose plan is awaiting review, and acts on
  what reviewers did there since the last poll.

    * **Approval** — a member's `/approve` comment, a member's 👍 on
      the plan comment, or a `camelot:approved` label a member applied
      → `:approve_plan_from_github`.
    * **Change request** — any other member comment → a `TaskMessage`
      (read by `Camelot.Board.PromptBuilder` on the next agent turn),
      then `:request_plan_changes`.

  Comments left alongside an approval are still recorded as messages,
  so last-minute notes reach the executing agent.

  Trust comes from `Camelot.Github.IssueTrust`. A stranger's comment is
  ignored — no message, no transition — until a project **owner** 👍s
  it, and then only as a change request: a stranger's `/approve` is
  never a command. The 👍 is void if the comment was edited after it.

  Only comments posted after the plan comment count (GitHub comment
  ids increase monotonically). The full comment list is fetched rather
  than `since: issue_comments_seen_at`, because GitHub's `since` filters
  on `updated_at` and a reaction does not bump it: an owner vouching
  for a stranger's comment after it was first seen would otherwise
  never be noticed. `issue_comments_seen_at` is instead applied
  client-side — to a member comment's `created_at`, and to the owner
  👍's `created_at` for a stranger comment.

  Like `Camelot.Board.Changes.CheckPrStatus`, this never raises: it
  runs unattended in Oban, and a GitHub failure just waits for the next
  poll.
  """
  use Ash.Resource.Change

  alias Camelot.Board.Changes.CheckPrStatus
  alias Camelot.Board.Task
  alias Camelot.Board.TaskMessage
  alias Camelot.Github.Client
  alias Camelot.Github.IssueTrust

  require Logger

  @approved_label "camelot:approved"
  @approve_command ~r/\A\s*\/approve(\s|\z)/

  @typedoc """
  What was read off the issue for one poll:

    * `comments` — the issue's comments.
    * `plan_reactions` — reactions on the plan comment.
    * `comment_reactions` — reactions on strangers' comments, by id.
    * `approved_label_actor` — who applied `camelot:approved`, if it is
      on the issue.
  """
  @type activity :: %{
          comments: [map()],
          plan_reactions: [map()],
          comment_reactions: %{optional(integer()) => [map()]},
          approved_label_actor: IssueTrust.github_user_id()
        }

  @type outcome :: :approved | :changes_requested | :no_change | {:error, term()}

  @impl true
  @spec change(
          Ash.Changeset.t(),
          keyword(),
          Ash.Resource.Change.context()
        ) :: Ash.Changeset.t()
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, task ->
      task = Ash.load!(task, [:project, creator: [:github_installations]], authorize?: false)
      check(task)
      {:ok, task}
    end)
  end

  defp check(task) do
    owner = task.project.github_owner
    repo = task.project.github_repo
    number = task.issue_number
    opts = [installation_id: CheckPrStatus.installation_id(task)]

    with {:ok, comments} <- Client.list_issue_comments(owner, repo, number, opts),
         {:ok, plan_reactions} <- Client.list_comment_reactions(owner, repo, task.plan_comment_id, opts),
         {:ok, issue} <- Client.get_issue(owner, repo, number, opts),
         {:ok, label_actor} <- approved_label_actor(owner, repo, issue, opts) do
      apply_activity(task, %{
        comments: comments,
        plan_reactions: plan_reactions,
        comment_reactions: stranger_reactions(owner, repo, pending_stranger_comment_ids(task, comments), opts),
        approved_label_actor: label_actor
      })
    else
      {:error, reason} ->
        Logger.warning("Failed to check issue plan for task #{task.id}: #{inspect(reason)}")
    end
  end

  defp approved_label_actor(owner, repo, issue, opts) do
    issue["labels"]
    |> List.wrap()
    |> Enum.any?(&(&1["name"] == @approved_label))
    |> fetch_label_actor(owner, repo, issue, opts)
  end

  defp fetch_label_actor(true, owner, repo, issue, opts) do
    owner |> Client.list_issue_events(repo, issue["number"], opts) |> label_actor()
  end

  defp fetch_label_actor(false, _owner, _repo, _issue, _opts), do: {:ok, nil}

  defp label_actor({:ok, events}) do
    events
    |> Enum.filter(&(&1["event"] == "labeled" and get_in(&1, ["label", "name"]) == @approved_label))
    |> List.last()
    |> event_actor()
  end

  defp label_actor({:error, reason}), do: {:error, reason}

  defp event_actor(nil), do: {:ok, nil}
  defp event_actor(event), do: {:ok, IssueTrust.actor_id(event)}

  # Best effort: a failed reaction fetch just means that stranger's
  # comment stays unvouched-for until the next poll.
  defp stranger_reactions(owner, repo, comment_ids, opts) do
    Map.new(comment_ids, fn id ->
      case Client.list_comment_reactions(owner, repo, id, opts) do
        {:ok, reactions} -> {id, reactions}
        {:error, _reason} -> {id, []}
      end
    end)
  end

  @doc """
  Ids of comments posted after the plan comment by someone who is not
  a project member — the only comments whose reactions need fetching.
  """
  @spec pending_stranger_comment_ids(Task.t(), [map()]) :: [integer()]
  def pending_stranger_comment_ids(task, comments) do
    task
    |> reviewable_comments(comments)
    |> Enum.reject(&IssueTrust.trusted?(IssueTrust.actor_id(&1), task.project_id))
    |> Enum.map(& &1["id"])
  end

  @doc """
  Applies one poll's `activity` to `task`: approves, requests changes,
  or just records the poll. Always stamps `issue_comments_seen_at` and
  broadcasts the task.
  """
  @spec apply_activity(Task.t(), activity()) :: outcome()
  def apply_activity(task, activity) do
    signals =
      task
      |> reviewable_comments(activity.comments)
      |> Enum.flat_map(&comment_signal(&1, task, activity.comment_reactions))

    messages = for {:message, body} <- signals, do: body
    approved? = :approve in signals or plan_reaction_approval?(task, activity) or label_approval?(task, activity)

    Enum.each(messages, &record_message(task, &1))

    approved?
    |> outcome(messages)
    |> transition(task)
  end

  defp reviewable_comments(task, comments) do
    comments
    |> Enum.filter(&(&1["id"] > task.plan_comment_id))
    |> Enum.reject(&CheckPrStatus.bot_authored?/1)
    |> Enum.sort_by(& &1["id"])
  end

  defp comment_signal(comment, task, comment_reactions) do
    comment
    |> IssueTrust.actor_id()
    |> IssueTrust.trusted?(task.project_id)
    |> trusted_signal(comment, task, comment_reactions)
  end

  defp trusted_signal(true, comment, task, _comment_reactions) do
    comment["created_at"]
    |> unseen?(task.issue_comments_seen_at)
    |> member_signals(comment["body"] || "")
  end

  defp trusted_signal(false, comment, task, comment_reactions) do
    reactions = Map.get(comment_reactions, comment["id"], [])

    comment
    |> IssueTrust.owner_approval(reactions, task.project_id)
    |> vouched_signal(comment, task)
  end

  defp vouched_signal(nil, _comment, _task), do: []

  defp vouched_signal(approval, comment, task) do
    approval["created_at"]
    |> unseen?(task.issue_comments_seen_at)
    |> vouched_signals(comment["body"] || "")
  end

  defp vouched_signals(true, body), do: [{:message, body}]
  defp vouched_signals(false, _body), do: []

  defp member_signals(false, _body), do: []
  defp member_signals(true, body), do: [@approve_command |> Regex.match?(body) |> member_signal(body)]

  defp member_signal(true, _body), do: :approve
  defp member_signal(false, body), do: {:message, body}

  defp plan_reaction_approval?(task, activity) do
    Enum.any?(activity.plan_reactions, fn reaction ->
      IssueTrust.thumbs_up?(reaction) and
        not CheckPrStatus.bot_authored?(reaction) and
        IssueTrust.trusted?(IssueTrust.actor_id(reaction), task.project_id)
    end)
  end

  defp label_approval?(task, activity) do
    IssueTrust.trusted?(activity.approved_label_actor, task.project_id)
  end

  defp unseen?(_created_at, nil), do: true
  defp unseen?(nil, _seen_at), do: false

  defp unseen?(created_at, seen_at) do
    case DateTime.from_iso8601(created_at) do
      {:ok, created, _offset} -> DateTime.after?(created, seen_at)
      {:error, _reason} -> false
    end
  end

  defp record_message(task, body) do
    Ash.create!(TaskMessage, %{role: :user, content: body, task_id: task.id})
  end

  defp outcome(true, _messages), do: {:approved, :approve_plan_from_github}
  defp outcome(false, []), do: {:no_change, :mark_issue_comments_seen}
  defp outcome(false, _messages), do: {:changes_requested, :request_plan_changes}

  defp transition({outcome, action}, task) do
    case Ash.update(task, %{issue_comments_seen_at: DateTime.utc_now()}, action: action) do
      {:ok, updated} ->
        broadcast(updated)
        log_outcome(outcome, task)
        outcome

      {:error, error} ->
        Logger.warning("Failed transition #{action} for task #{task.id}: #{inspect(error)}")
        {:error, error}
    end
  end

  defp log_outcome(:no_change, _task), do: :ok
  defp log_outcome(outcome, task), do: Logger.info("Task #{task.id} → #{outcome} (GitHub issue)")

  defp broadcast(task) do
    Phoenix.PubSub.broadcast(Camelot.PubSub, "board", {:task_updated, task})
    Phoenix.PubSub.broadcast(Camelot.PubSub, "task:#{task.id}", {:task_updated, task})
  end
end
