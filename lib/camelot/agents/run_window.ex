defmodule Camelot.Agents.RunWindow do
  @moduledoc """
  A weekly time range in which queued cards may be dispatched.

  Both bounds are **UTC minutes of the week**, Monday 00:00 UTC being
  `0` and Sunday 23:59 UTC `10079` — see
  `Camelot.Scheduling.Windows`. `start_minute` is inclusive and
  `end_minute` exclusive; an `end_minute` below `start_minute` wraps
  past Sunday into Monday. Converting from and to the user's own time
  zone is a UI concern (`Camelot.TimeZone`).

  Embedded, not a table: it only ever exists as part of a
  `Camelot.Agents.UsagePolicy` or a `Camelot.Board.Task` override.
  """
  use Ash.Resource, data_layer: :embedded

  @last_minute 7 * 24 * 60 - 1

  attributes do
    attribute :start_minute, :integer do
      allow_nil?(false)
      public?(true)
      constraints(min: 0, max: @last_minute)
    end

    attribute :end_minute, :integer do
      allow_nil?(false)
      public?(true)
      constraints(min: 0, max: @last_minute)
    end
  end

  validations do
    validate(Camelot.Agents.RunWindow.Validations.NonEmpty)
  end
end
