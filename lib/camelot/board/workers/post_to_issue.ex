defmodule Camelot.Board.Workers.PostToIssue do
  @moduledoc """
  Writes one plan-related comment back to the GitHub issue a task was
  imported from — the plan itself (`"plan"`) or a note that the plan
  was approved in the Camelot UI (`"approved_in_camelot"`). Enqueued by
  `Camelot.Board.Notifiers.EnqueueIssuePost`.

  A GitHub failure returns `{:error, reason}` so Oban retries it; a
  task that has since been deleted or unlinked is dropped.
  """
  use Oban.Worker, queue: :github, max_attempts: 3

  alias Camelot.Board.Changes.PostPlanToIssue
  alias Camelot.Board.Task

  @impl true
  @spec perform(Oban.Job.t()) :: :ok | {:error, term()}
  def perform(%Oban.Job{args: %{"task_id" => task_id, "kind" => kind}}) do
    case Ash.get(Task, task_id, load: PostPlanToIssue.load(), authorize?: false) do
      {:ok, task} -> kind |> post(task) |> result()
      {:error, _not_found} -> :ok
    end
  end

  @spec post(String.t(), Task.t()) :: :ok | :skipped | {:error, term()}
  defp post("plan", task), do: PostPlanToIssue.post_plan(task)
  defp post("approved_in_camelot", task), do: PostPlanToIssue.post_ui_approval(task)
  defp post(_unknown, _task), do: :skipped

  defp result({:error, reason}), do: {:error, reason}
  defp result(_done), do: :ok
end
