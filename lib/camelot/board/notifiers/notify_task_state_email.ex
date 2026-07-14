defmodule Camelot.Board.Notifiers.NotifyTaskStateEmail do
  @moduledoc """
  Enqueues a `Camelot.Board.Workers.SendTaskStateEmail` job whenever a
  task transitions into `:waiting_for_input`, `:error`, or `:done`.

  Attached per-action (not resource-wide) to the six transitions that can
  reach one of those states, so it never fires for unrelated updates.
  """
  use Ash.Notifier

  alias Ash.Notifier.Notification
  alias Camelot.Board.Workers.SendTaskStateEmail

  @impl true
  @spec notify(Notification.t()) :: :ok
  def notify(%Notification{data: task}) do
    task
    |> notification_kind()
    |> enqueue(task)
  end

  @spec notification_kind(Ash.Resource.record()) :: atom() | nil
  defp notification_kind(%{state: :waiting_for_input}), do: :waiting_for_input
  defp notification_kind(%{state: :error}), do: :error
  defp notification_kind(%{stage: :done}), do: :done
  defp notification_kind(_task), do: nil

  @spec enqueue(atom() | nil, Ash.Resource.record()) :: :ok
  defp enqueue(nil, _task), do: :ok

  defp enqueue(kind, task) do
    %{task_id: task.id, kind: to_string(kind)}
    |> SendTaskStateEmail.new()
    |> Oban.insert()

    :ok
  end
end
