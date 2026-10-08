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
    user = Ash.get!(User, user_id)

    if notify?(user, kind) do
      Sender.send(user, String.to_existing_atom(kind), args["window"])
    end

    :ok
  end

  @spec notify?(Ash.Resource.record(), String.t()) :: boolean()
  defp notify?(user, "paused"), do: user.notify_on_usage_limit_paused
  defp notify?(user, "resumed"), do: user.notify_on_usage_limit_resumed
end
