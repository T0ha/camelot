defmodule Camelot.Telemetry.JobFailuresTest do
  @moduledoc """
  A background job that fails says so.

  Oban reports a failed job through `[:oban, :job, :exception]` and
  nothing else: `Oban.Telemetry.attach_default_logger/1` is not called
  anywhere in this application, and `Oban.Queue.Executor` writes no log
  of its own. So a job that raised produced no log line, no PostHog
  event and no error-tracking entry — the "Oban job failures are not
  captured anywhere user-linkable" half of GH#168 §1g.
  """
  use Camelot.DataCase, async: false

  import ExUnit.CaptureLog

  alias Camelot.Telemetry.Context

  @event [:oban, :job, :exception]

  defp job(args, overrides \\ []) do
    fields =
      Keyword.merge(
        [
          id: System.unique_integer([:positive]),
          args: args,
          worker: "Camelot.Board.Workers.SendTaskStateEmail",
          queue: "notifications",
          attempt: 3,
          max_attempts: 3
        ],
        overrides
      )

    struct!(Oban.Job, fields)
  end

  defp fail(job, state \\ :failure) do
    {reason, stacktrace} =
      try do
        raise "job blew up"
      rescue
        error -> {error, __STACKTRACE__}
      end

    :telemetry.execute(@event, %{duration: 1}, %{
      job: job,
      state: state,
      kind: :error,
      reason: reason,
      stacktrace: stacktrace
    })
  end

  defp exceptions do
    Enum.filter(PostHog.Test.all_captured(), &(&1.event == "$exception"))
  end

  describe "a job that has run out of attempts" do
    test "is reported to error tracking with the ids from its args" do
      user_id = Ecto.UUID.generate()
      task_id = Ecto.UUID.generate()

      capture_log(fn ->
        fail(job(%{"task_id" => task_id, "user_id" => user_id, "kind" => "error"}))
      end)

      assert [exception | _rest] = exceptions()

      assert exception.properties[:task_id] == task_id
      assert exception.properties[:user_id] == user_id
      assert exception.properties[:worker] == "Camelot.Board.Workers.SendTaskStateEmail"
      assert exception.properties[:queue] == "notifications"
    end

    test "is attributed to the person the job was running for" do
      user_id = Ecto.UUID.generate()

      capture_log(fn -> fail(job(%{"user_id" => user_id})) end)

      assert [exception | _rest] = exceptions()
      assert exception.distinct_id == user_id
    end

    test "carries the environment every other capture carries" do
      capture_log(fn -> fail(job(%{"task_id" => Ecto.UUID.generate()})) end)

      assert [exception | _rest] = exceptions()
      assert exception.properties[:environment] == Context.environment()
    end

    test "logs the failure with the ids as metadata rather than in the message" do
      task_id = Ecto.UUID.generate()

      log = capture_log(fn -> fail(job(%{"task_id" => task_id})) end)

      assert log =~ "Oban job failed"
      refute log =~ "#{task_id} failed"
    end
  end

  describe "a job that will be retried" do
    test "is logged but not reported as an exception" do
      log =
        capture_log(fn ->
          fail(job(%{"task_id" => Ecto.UUID.generate()}, attempt: 1, max_attempts: 3))
        end)

      assert log =~ "Oban job failed"
      assert exceptions() == []
    end
  end

  describe "arguments" do
    test "only the bounded id keys are reported, never the whole args map" do
      capture_log(fn ->
        fail(job(%{"task_id" => Ecto.UUID.generate(), "secret" => "hunter2"}))
      end)

      assert [exception | _rest] = exceptions()

      refute exception.properties |> Map.values() |> Enum.member?("hunter2")
      refute Map.has_key?(exception.properties, :secret)
      refute Map.has_key?(exception.properties, :args)
    end
  end
end
