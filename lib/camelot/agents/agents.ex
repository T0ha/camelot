defmodule Camelot.Agents do
  @moduledoc """
  Domain for AI agent management and session tracking.
  """
  use Ash.Domain

  resources do
    resource(Camelot.Agents.Agent)
    resource(Camelot.Agents.Session)
  end
end
