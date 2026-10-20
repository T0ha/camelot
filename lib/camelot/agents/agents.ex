defmodule Camelot.Agents do
  @moduledoc """
  Domain for AI agent management and session tracking.
  """
  use Ash.Domain

  resources do
    resource Camelot.Agents.Agent do
      define(:get_agent_by_slug, action: :read, get_by: [:slug])
    end

    resource(Camelot.Agents.Session)
  end
end
