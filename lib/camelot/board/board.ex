defmodule Camelot.Board do
  @moduledoc """
  Domain for kanban board task management with
  state machine transitions.
  """
  use Ash.Domain

  resources do
    resource(Camelot.Board.Task)
    resource(Camelot.Board.TaskMessage)
  end
end
