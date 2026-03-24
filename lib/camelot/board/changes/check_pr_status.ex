defmodule Camelot.Board.Changes.CheckPrStatus do
  @moduledoc """
  Ash change that checks GitHub PR status and transitions
  the task accordingly.

  Transitions:
  - merged → done (via complete)
  - closed → cancelled (via cancel)
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
           Client.list_pull_request_commits(owner, repo, pr) do
      apply_pr_state(task, pr_data, reviews, comments, commits)
    else
      {:error, reason} ->
        Logger.warning(
          "Failed to check PR for task #{task.id}: " <>
            "#{inspect(reason)}"
        )
    end
  end

  defp apply_pr_state(task, pr, reviews, comments, commits) do
    cond do
      pr["merged"] == true ->
        transition(task, :complete)

      pr["state"] == "closed" ->
        transition(task, :cancel)

      has_review_state?(reviews, "CHANGES_REQUESTED") &&
          task.state == :waiting_for_input ->
        transition_with_seen_at(task, comments)

      has_review_state?(reviews, "APPROVED") &&
          task.state == :waiting_for_input ->
        transition(task, :complete)

      has_new_comments?(task, pr, comments, commits) &&
          task.state == :waiting_for_input ->
        transition_with_seen_at(task, comments)

      true ->
        :ok
    end
  end

  defp has_review_state?(reviews, state) do
    Enum.any?(reviews, &(&1["state"] == state))
  end

  defp has_new_comments?(task, pr, comments, commits) do
    pr_author = get_in(pr, ["user", "login"])
    last_commit_date = last_commit_date(commits)
    seen_at = task.pr_comments_seen_at

    comments
    |> Enum.reject(&(get_in(&1, ["user", "login"]) == pr_author))
    |> Enum.any?(fn comment ->
      created = comment["created_at"]

      newer_than_commit? =
        case {last_commit_date, created} do
          {nil, _} -> true
          {_, nil} -> false
          {cd, cr} -> cr > cd
        end

      not_seen? =
        case seen_at do
          nil ->
            true

          dt ->
            created >
              DateTime.to_iso8601(dt)
        end

      newer_than_commit? and not_seen?
    end)
  end

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
