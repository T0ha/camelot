defmodule Camelot.Board.Changes.CheckPrStatus do
  @moduledoc """
  Ash change that checks GitHub PR status and transitions
  the task accordingly.

  Transitions:
  - merged → done (via approve_pr)
  - closed → cancelled (via cancel)
  - changes_requested → pr_fix (via request_pr_changes)
  - approved → done (via approve_pr)
  - pr_created → pr_review (via submit_pr_review)
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

    with {:ok, pr} <-
           Client.get_pull_request(
             project.github_owner,
             project.github_repo,
             task.pr_number
           ),
         {:ok, reviews} <-
           Client.list_pull_request_reviews(
             project.github_owner,
             project.github_repo,
             task.pr_number
           ) do
      apply_pr_state(task, pr, reviews)
    else
      {:error, reason} ->
        Logger.warning(
          "Failed to check PR for task #{task.id}: " <>
            "#{inspect(reason)}"
        )
    end
  end

  defp apply_pr_state(task, pr, reviews) do
    cond do
      pr["merged"] == true ->
        transition(task, :approve_pr)

      pr["state"] == "closed" ->
        transition(task, :cancel)

      has_review_state?(reviews, "CHANGES_REQUESTED") &&
          task.status == :pr_review ->
        transition(task, :request_pr_changes)

      has_review_state?(reviews, "APPROVED") &&
          task.status == :pr_review ->
        transition(task, :approve_pr)

      task.status == :pr_created ->
        transition(task, :submit_pr_review)

      true ->
        :ok
    end
  end

  defp has_review_state?(reviews, state) do
    Enum.any?(reviews, &(&1["state"] == state))
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
