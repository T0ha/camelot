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

  # `docs/telemetry.md` is the reference anyone reaches for after
  # seeing an event name in PostHog, so a name that reaches the wire
  # without reaching the doc is a name nobody can look up. Both halves
  # of the catalogue are derived rather than listed here, so a new
  # event is either documented or this fails.
  test "every event the code can capture is documented under its own name" do
    doc = File.read!("docs/telemetry.md")

    undocumented =
      Events.event_names()
      |> Map.values()
      |> Enum.concat(call_site_events())
      |> Enum.uniq()
      |> Enum.reject(&String.contains?(doc, "`#{&1}`"))

    assert undocumented == []
  end

  # Events captured outside the Ash catalogue — from controllers and
  # LiveViews — named by the string literal they are captured with.
  # `$set` and the other PostHog built-ins are not product events and
  # are deliberately outside the pattern.
  @spec call_site_events() :: [String.t()]
  defp call_site_events do
    pattern = ~r/capture\(\s*"([a-z][a-z0-9_]*)"/

    "lib/**/*.ex"
    |> Path.wildcard()
    |> Enum.flat_map(fn file ->
      pattern
      |> Regex.scan(File.read!(file), capture: :all_but_first)
      |> List.flatten()
    end)
  end
end
