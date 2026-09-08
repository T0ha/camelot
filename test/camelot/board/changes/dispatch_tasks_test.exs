defmodule Camelot.Board.Changes.DispatchTasksTest do
  use ExUnit.Case, async: true

  alias Camelot.Board.Changes.DispatchTasks
  alias Camelot.Board.Task
  alias Camelot.Projects.Project

  defp task(attrs) do
    defaults = %{
      state: :queued,
      stage: :todo,
      project: %Project{status: :active}
    }

    struct!(Task, Map.merge(defaults, attrs))
  end

  describe "dispatchable?/1" do
    test "a queued task in a dispatchable stage dispatches" do
      for stage <- [:todo, :planning, :executing, :pr] do
        assert DispatchTasks.dispatchable?(task(%{stage: stage}))
      end
    end

    test "a task that is not queued does not dispatch" do
      for state <- [:in_progress, :waiting_for_input, :error] do
        refute DispatchTasks.dispatchable?(task(%{state: state}))
      end
    end

    test "a task outside the dispatchable stages does not dispatch" do
      for stage <- [:draft, :done, :cancelled] do
        refute DispatchTasks.dispatchable?(task(%{stage: stage}))
      end
    end

    test "a task in an archived project does not dispatch" do
      # Archiving a project has to stop its agents; otherwise the
      # every-minute dispatcher keeps burning runner slots on a board
      # that has been retired.
      refute DispatchTasks.dispatchable?(task(%{project: %Project{status: :archived}}))
    end
  end
end
