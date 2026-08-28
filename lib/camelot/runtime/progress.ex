defmodule Camelot.Runtime.Progress do
  @moduledoc """
  Provisioning progress for a session that has not produced
  agent output yet.

  Between "the task starts running" and "the agent CLI prints
  its first byte" a lot can happen — the session waits for a
  pool slot, Swarm schedules a replica, a worker pulls the
  runner image, and the container entrypoint clones the repo
  and installs the toolchain. Each step can legitimately take
  minutes (see `Camelot.Runtime.Runner.Swarm.ExecSession`),
  and none of it used to reach the user: the task page showed
  a `running` badge and an empty panel, which reads as frozen.

  `report/4` is the single funnel for those lines. It persists
  the latest one on the session (so a page load mid-flight, or
  a second viewer, sees it) and broadcasts it on the task's
  PubSub topic (so open pages update live).

  Best-effort by design: a progress line is never worth
  failing a run over, so persistence errors are logged and
  swallowed.
  """

  alias Camelot.Agents.Session

  require Logger

  @type phase :: :queued | :provisioning | :pulling_image | :starting | :workspace | :running

  @doc """
  Record and broadcast one progress line.

  `task_id` may be nil for sessions without a task (bootstrap
  runs) — nothing is broadcast then. `session_id` may be nil
  before a session row exists — nothing is persisted then.
  """
  @spec report(String.t() | nil, String.t() | nil, phase(), String.t()) :: :ok
  def report(task_id, session_id, phase, message) when is_atom(phase) and is_binary(message) do
    persist(session_id, phase, message)
    broadcast(task_id, session_id, phase, message)
  end

  defp persist(nil, _phase, _message), do: :ok

  defp persist(session_id, phase, message) do
    case Ash.get(Session, session_id, authorize?: false) do
      {:ok, session} ->
        update_session(session, phase, message)

      {:error, reason} ->
        Logger.debug("Progress: session #{session_id} not found: #{inspect(reason)}")
        :ok
    end
  end

  defp update_session(session, phase, message) do
    case Ash.update(session, %{progress_phase: phase, progress_message: message}, action: :report_progress) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("Progress: could not persist progress: #{inspect(reason)}")
        :ok
    end
  end

  defp broadcast(nil, _session_id, _phase, _message), do: :ok

  defp broadcast(task_id, session_id, phase, message) do
    Phoenix.PubSub.broadcast(
      Camelot.PubSub,
      "task:#{task_id}",
      {:runner_progress, task_id,
       %{
         session_id: session_id,
         phase: phase,
         message: message,
         at: DateTime.utc_now()
       }}
    )

    :ok
  end
end
