defmodule Camelot.Telemetry.BackendExceptionTest do
  @moduledoc """
  A server-side crash names the person it happened to.

  PostHog's own logger handler turns anything logged with a
  `crash_reason` — a LiveView crash, a GenServer crash, an Oban job
  failure — into an `$exception`. It captures through
  `PostHog.bare_capture/4` directly, so it never passes through
  `Camelot.Telemetry.Capture` and picks up none of the properties
  that module merges: without configuration it reports every backend
  crash in both clusters as one synthetic person, `"unknown"`, with
  no `environment` to tell the clusters apart and none of the
  `Logger` metadata this application sets per process.
  """
  use Camelot.DataCase, async: true

  import ExUnit.CaptureLog

  alias Camelot.Telemetry.Context

  require Logger

  defp crash(message) do
    capture_log(fn ->
      try do
        raise message
      rescue
        error ->
          # `crash_reason` is a prod-only log field (`config/runtime.exs`),
          # but it is what promotes a record to an error-tracking entry
          # in every environment.
          # credo:disable-for-next-line Credo.Check.Warning.MissedMetadataKeyInLoggerConfig
          Logger.error(Exception.message(error), crash_reason: {error, __STACKTRACE__})
      end
    end)
  end

  defp exceptions do
    Enum.filter(PostHog.Test.all_captured(), &(&1.event == "$exception"))
  end

  test "carries the environment every other capture carries" do
    crash("boom")

    assert [exception | _rest] = exceptions()
    assert exception.properties[:environment] == Context.environment()
  end

  test "is attributed to the person the process is working for" do
    user_id = Ecto.UUID.generate()

    Context.put_person_metadata(user_id)
    crash("boom")

    assert [exception | _rest] = exceptions()
    assert exception.distinct_id == user_id
    assert exception.properties[:user_id] == user_id
  end

  test "carries the process's task and project ids" do
    task_id = Ecto.UUID.generate()
    project_id = Ecto.UUID.generate()

    Logger.metadata(task_id: task_id, project_id: project_id)
    crash("boom")

    assert [exception | _rest] = exceptions()
    assert exception.properties[:task_id] == task_id
    assert exception.properties[:project_id] == project_id
  end

  test "falls back to no person rather than inventing one" do
    crash("boom")

    assert [exception | _rest] = exceptions()
    assert exception.distinct_id == "unknown"
  end
end
