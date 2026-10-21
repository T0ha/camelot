defmodule Camelot.Agents do
  @moduledoc """
  Domain for AI agent management and session tracking.
  """
  use Ash.Domain

  resources do
    resource(Camelot.Agents.Agent)
    resource(Camelot.Agents.Session)
    resource(Camelot.Agents.UsagePolicy)
    resource(Camelot.Agents.UsageSnapshot)
  end
end
