defmodule Camelot.Board.Notifiers.EnqueueIssuePost do
  @moduledoc """
  Enqueues a `Camelot.Board.Workers.PostToIssue` job after a plan
  transition on a task imported from a GitHub issue:

    * `:submit_plan` — post the plan as an issue comment for review.
    * `:approve_plan` — tell the issue the plan was approved in Camelot.

  A notifier rather than an `after_action` hook so the GitHub call runs
  after the transaction commits and outside it, on the `:github`
  queue, mirroring `Camelot.Board.Notifiers.NotifyTaskStateEmail`.
  Tasks without an `issue_number` enqueue nothing.
  """
  use Ash.Notifier

  alias Ash.Notifier.Notification
  alias Camelot.Board.Workers.PostToIssue

  @impl true
  @spec notify(Notification.t()) :: :ok
  def notify(%Notification{data: %{issue_number: nil}}), do: :ok

  def notify(%Notification{data: task, action: %{name: action}}) do
    action
    |> kind()
    |> enqueue(task)
  end

  @spec kind(atom()) :: String.t() | nil
  defp kind(:submit_plan), do: "plan"
  defp kind(:approve_plan), do: "approved_in_camelot"
  defp kind(_action), do: nil

  @spec enqueue(String.t() | nil, Ash.Resource.record()) :: :ok
  defp enqueue(nil, _task), do: :ok

  defp enqueue(kind, task) do
    %{task_id: task.id, kind: kind}
    |> PostToIssue.new()
    |> Oban.insert()

    :ok
  end
end
