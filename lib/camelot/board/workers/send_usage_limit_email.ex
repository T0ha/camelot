defmodule Camelot.Board.Workers.SendUsageLimitEmail do
  @moduledoc """
  Delivers the usage-limit pause/resume email for one user, unless
  they've opted out of that notification kind.

  One job per credential event (not per task) — `Camelot.Board.
  UsageLimitPause` enqueues exactly one of these per pause and per
  batch of resumes, regardless of how many cards were affected.
  """
  use Oban.Worker, queue: :notifications, max_attempts: 3

  alias Camelot.Accounts.User
  alias Camelot.Board.Task.Senders.SendUsageLimitEmail, as: Sender

  @impl true
  @spec perform(Oban.Job.t()) :: :ok
  def perform(%Oban.Job{args: %{"user_id" => user_id, "kind" => kind} = args}) do
    case known_kind(kind) do
      {:ok, kind_atom} ->
        user = Ash.get!(User, user_id)
        if notify?(user, kind_atom), do: Sender.send(user, kind_atom, args["window"])

      :error ->
        :ok
    end

    :ok
  end

  # Only ever "paused" or "resumed" — `UsageLimitPause.enqueue_email/3`
  # is the sole producer. Validated explicitly (rather than
  # `String.to_existing_atom/1`) so a retried job after a hot-code
  # upgrade that dropped one of the atoms can't crash the worker.
  @spec known_kind(String.t()) :: {:ok, atom()} | :error
  defp known_kind("paused"), do: {:ok, :paused}
  defp known_kind("resumed"), do: {:ok, :resumed}
  defp known_kind(_other), do: :error

  @spec notify?(Ash.Resource.record(), atom()) :: boolean()
  defp notify?(user, :paused), do: user.notify_on_usage_limit_paused
  defp notify?(user, :resumed), do: user.notify_on_usage_limit_resumed
end
