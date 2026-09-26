defmodule Camelot.Telemetry.JobFailures do
  @moduledoc """
  Gives a failed background job a voice.

  Oban announces a failed job through `[:oban, :job, :exception]` and
  nothing else. `Oban.Telemetry.attach_default_logger/1` is not called
  anywhere in this application and `Oban.Queue.Executor` writes no log
  of its own, so a job that raised used to produce no log line, no
  PostHog event and no error-tracking entry at all — invisible in
  exactly the way GH#168 §1g describes.

  The failure is reported as a `Logger` record rather than as a
  product event: PostHog's error-tracking handler turns anything
  carrying a `crash_reason` into an `$exception`, so one call gives
  both the JSON log line and the error-tracking entry, with the same
  metadata on each and no second mechanism to keep in step.

  Only the *terminal* failure carries a `crash_reason`. Oban emits
  this event once per attempt, and a job that retries three times is
  one failure, not three — so the attempts in between are logged at
  `warning`, which the handler leaves alone.
  """

  alias Oban.Job

  require Logger

  @event [:oban, :job, :exception]

  # Job arguments are application data and can hold anything a caller
  # put there, so the whole map is never reported. These three are the
  # ids the funnel and the logs already join on.
  @id_keys [{"user_id", :user_id}, {"task_id", :task_id}, {"project_id", :project_id}]

  @doc """
  Attaches this handler. Called once from `Camelot.Application.start/2`.
  """
  @spec attach() :: :ok
  def attach do
    :telemetry.attach(__MODULE__, @event, &__MODULE__.handle_event/4, nil)

    :ok
  end

  @doc false
  @spec handle_event(:telemetry.event_name(), :telemetry.event_measurements(), map(), term()) ::
          :ok
  def handle_event(@event, _measurements, %{job: %Job{} = job} = metadata, _config) do
    level = level(job, metadata)

    Logger.log(level, "Oban job failed", failure_metadata(job, metadata, level))
  rescue
    # `:telemetry` detaches a handler that raises, globally and for
    # the life of the node: one odd payload would take every later
    # job failure back to being silent.
    error ->
      Logger.warning("Oban job failure report failed", reason: error.__struct__)

      :ok
  end

  def handle_event(@event, _measurements, _metadata, _config), do: :ok

  # A job Oban will pick up again has not failed yet, and reporting it
  # as an exception would count one failure once per attempt.
  @spec level(Job.t(), map()) :: :error | :warning
  defp level(_job, %{state: :discard}), do: :error
  defp level(%Job{attempt: attempt, max_attempts: max}, _metadata) when attempt >= max, do: :error
  defp level(_job, _metadata), do: :warning

  @spec failure_metadata(Job.t(), map(), :error | :warning) :: keyword()
  defp failure_metadata(%Job{} = job, metadata, level) do
    [worker: job.worker, queue: job.queue, job_attempt: job.attempt] ++
      crash_reason(metadata, level) ++ ids(job.args)
  end

  # The `crash_reason` is what promotes the record from a log line to
  # an error-tracking entry, so it is attached only where the failure
  # is final.
  @spec crash_reason(map(), :error | :warning) :: keyword()
  defp crash_reason(%{reason: reason, stacktrace: stacktrace}, :error) do
    [crash_reason: {reason, stacktrace}]
  end

  defp crash_reason(_metadata, _level), do: []

  # `distinct_id` is what PostHog's error-tracking handler reads to
  # decide whose crash this is; a job that knows nothing about a user
  # stays on `"unknown"` rather than being attributed to a guess.
  @spec ids(map() | nil) :: keyword()
  defp ids(%{} = args) do
    ids = Enum.flat_map(@id_keys, &id(args, &1))

    case Keyword.fetch(ids, :user_id) do
      {:ok, user_id} -> [{:distinct_id, user_id} | ids]
      :error -> ids
    end
  end

  defp ids(_no_args), do: []

  @spec id(map(), {String.t(), atom()}) :: keyword()
  defp id(args, {arg_key, metadata_key}) do
    case Map.get(args, arg_key) do
      value when is_binary(value) -> [{metadata_key, value}]
      _not_an_id -> []
    end
  end
end
