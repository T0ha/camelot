defmodule Camelot.Telemetry.EventsTest do
  @moduledoc """
  Structural guards on the event catalogue.

  Every entry is a `{resource, action}` pair matched by name, so a
  renamed action or a resource that loses its notifier takes the event
  off the air without failing to compile — the funnel would simply go
  quiet, which is the failure this instrumentation exists to prevent.
  """
  use ExUnit.Case, async: true

  alias Ash.Resource.Info
  alias Camelot.Telemetry.Events
  alias Camelot.Telemetry.Notifier

  test "every catalogued action exists on its resource" do
    missing =
      for {{resource, action}, event} <- Events.event_names(),
          is_nil(Info.action(resource, action)),
          do: {event, resource, action}

    assert missing == []
  end

  test "every catalogued resource registers the telemetry notifier" do
    unwired =
      for {{resource, _action}, event} <- Events.event_names(),
          Notifier not in Info.simple_notifiers(resource),
          do: {event, resource}

    assert unwired == []
  end

  test "an uncatalogued action resolves to :skip rather than an event" do
    assert Events.resolve(Camelot.Board.Task, :update, %{id: "id"}, nil) == :skip
  end
end
