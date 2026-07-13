defmodule Camelot.Board.Workers.SendTaskStateEmail do
  @moduledoc """
  Delivers the task-state-change email for one `kind` of transition
  (`"waiting_for_input"`, `"error"`, `"done"`), unless the task's creator
  has opted out of that notification kind.
  """
  use Oban.Worker, queue: :notifications, max_attempts: 3

  alias Camelot.Board.Task
  alias Camelot.Board.Task.Senders.SendStateChangeEmail

  @impl true
  @spec perform(Oban.Job.t()) :: :ok
  def perform(%Oban.Job{args: %{"task_id" => task_id, "kind" => kind}}) do
    task = Task |> Ash.get!(task_id) |> Ash.load!(:creator)

    if notify?(task.creator, kind) do
      SendStateChangeEmail.send(task, String.to_existing_atom(kind))
    end

    :ok
  end

  @spec notify?(Ash.Resource.record(), String.t()) :: boolean()
  defp notify?(creator, "waiting_for_input"), do: creator.notify_on_waiting_for_input
  defp notify?(creator, "error"), do: creator.notify_on_error
  defp notify?(creator, "done"), do: creator.notify_on_done
end
