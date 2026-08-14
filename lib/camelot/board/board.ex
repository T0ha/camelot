defmodule Camelot.Board do
  @moduledoc """
  Domain for kanban board task management with
  state machine transitions.
  """
  use Ash.Domain

  alias Camelot.Board.TaskAttachment

  require Ash.Query

  resources do
    resource(Camelot.Board.Task)
    resource(Camelot.Board.TaskMessage)
    resource(TaskAttachment)
  end

  @doc """
  Destroys every attachment for `task_id`, deleting each blob via
  its `TaskAttachment` destroy hook along the way. Called when the
  task's container (DockerEngine) or service (Swarm) is torn down —
  attachments feed a running agent, not the task's own lifecycle.
  """
  @spec purge_task_attachments!(Ecto.UUID.t()) :: :ok
  def purge_task_attachments!(task_id) do
    TaskAttachment
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.read!(authorize?: false)
    |> Enum.each(&Ash.destroy!(&1, authorize?: false))

    :ok
  end
end
