defmodule Camelot.Projects do
  @moduledoc """
  Domain for project management.
  """
  use Ash.Domain

  resources do
    resource(Camelot.Projects.Project)
  end
end
