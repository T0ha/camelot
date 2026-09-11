defmodule Camelot.Board.Interruption do
  @moduledoc """
  Recovery policy for runs cut short by infrastructure rather than by
  the agent: a deploy replacing the runner container, a Swarm service
  that vanished, an app restart that orphaned a session.

  Such a run is not a failure of the task, so erroring the card (and
  emailing its owner) on every deploy is wrong. Instead the task is put
  straight back to `:queued` and the every-minute `dispatch_tasks` cron
  resumes it from its current stage.

  A task that can *never* run — an unsatisfiable placement constraint,
  a deleted image — would otherwise re-queue forever, so the re-queues
  are counted (`Task.interrupt_requeues`, reset on any forward
  progress) and capped by `:camelot, :runner, :max_interrupt_requeues`.
  Past the cap the task errors as before, with the underlying reason
  attached.
  """

  alias Camelot.Board.Task

  require Logger

  @default_max_requeues 3

  @doc """
  Re-queue `task` after an infrastructure interruption, or error it
  once the re-queue cap is exhausted.

  `reason` is a human-readable description of what interrupted the run;
  it is logged either way and becomes `last_error` when the cap is hit.

  Pass `keep_runner_handle: true` when the runner service itself is
  still healthy and only its container was replaced, so the next
  dispatch reuses it instead of building a new one.
  """
  @spec requeue_or_error(Task.t(), String.t(), keyword()) ::
          {:ok, Task.t()} | {:error, term()}
  def requeue_or_error(task, reason, opts \\ [])

  def requeue_or_error(%Task{} = task, reason, opts) when is_binary(reason) do
    if requeue_allowed?(task) do
      requeue(task, reason, opts)
    else
      give_up(task, reason)
    end
  end

  @doc """
  Look the task up by id and apply `requeue_or_error/3`. Returns
  `{:error, :not_found}` when the task is gone (it may have been
  cancelled while its runner was still up).
  """
  @spec requeue_or_error_by_id(String.t(), String.t(), keyword()) ::
          {:ok, Task.t()} | {:error, term()}
  def requeue_or_error_by_id(task_id, reason, opts \\ []) when is_binary(task_id) do
    case Ash.get(Task, task_id) do
      {:ok, task} -> requeue_or_error(task, reason, opts)
      {:error, _} -> {:error, :not_found}
    end
  end

  @doc """
  How many consecutive interruption re-queues a task may accumulate
  before it is errored instead.
  """
  @spec max_requeues() :: non_neg_integer()
  def max_requeues do
    :camelot
    |> Application.get_env(:runner, [])
    |> Keyword.get(:max_interrupt_requeues, @default_max_requeues)
  end

  defp requeue_allowed?(%Task{interrupt_requeues: count}) do
    count < max_requeues()
  end

  defp requeue(%Task{} = task, reason, opts) do
    Logger.info(
      "Task #{task.id}: run interrupted (#{reason}); re-queueing " <>
        "(attempt #{task.interrupt_requeues + 1}/#{max_requeues()})"
    )

    params = %{keep_runner_handle: Keyword.get(opts, :keep_runner_handle, false)}

    case Ash.update(task, params, action: :requeue_interrupted) do
      {:ok, updated} ->
        broadcast(updated)
        {:ok, updated}

      # A task that has moved to a stage work can't resume from
      # (done/cancelled) needs no recovery — the interruption is moot.
      {:error, reason} ->
        Logger.info("Task #{task.id}: not re-queueable (#{inspect(reason)}); leaving as is")

        {:error, reason}
    end
  end

  defp give_up(%Task{} = task, reason) do
    message =
      "Re-queued #{task.interrupt_requeues} times after the runner was " <>
        "interrupted, without completing a run. Last interruption: #{reason}"

    Logger.warning("Task #{task.id}: interruption re-queue cap reached; marking error")

    case Ash.update(task, %{last_error: message}, action: :mark_error) do
      {:ok, updated} ->
        broadcast(updated)
        {:ok, updated}

      {:error, _} = err ->
        err
    end
  end

  defp broadcast(%Task{id: id} = task) do
    Phoenix.PubSub.broadcast(Camelot.PubSub, "task:#{id}", {:task_updated, task})
    Phoenix.PubSub.broadcast(Camelot.PubSub, "board", {:task_updated, task})
    :ok
  end
end
