defmodule Camelot.Telemetry.Notifier do
  @moduledoc """
  Generic `Ash.Notifier` with no DSL. Emits `[:camelot, :ash, :notify]`
  for every notification on resources that register it via
  `simple_notifiers:`, so any `:telemetry.attach` consumer (PostHog, an
  OTel exporter, ...) can observe resource lifecycle events without
  editing individual action definitions.

  Deciding which of those events are worth acting on lives in the
  attached handlers, not here — this notifier stays dumb and reusable.
  """
  use Ash.Notifier

  alias Ash.Notifier.Notification

  @impl true
  @spec notify(Notification.t()) :: :ok
  def notify(%Notification{resource: resource, action: action, actor: actor, data: data}) do
    :telemetry.execute(
      [:camelot, :ash, :notify],
      %{},
      %{resource: resource, action: action, actor: actor, data: data}
    )

    :ok
  end
end
