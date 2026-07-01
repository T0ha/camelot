defmodule Camelot.Projects do
  @moduledoc """
  Domain for project management.
  """
  use Ash.Domain

  resources do
    resource(Camelot.Projects.Project)
    resource(Camelot.Projects.Membership)
    resource(Camelot.Projects.Mcp)
    resource(Camelot.Projects.EnvVar)
  end
end
