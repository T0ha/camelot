defmodule Camelot.Board.ColumnTest do
  use ExUnit.Case, async: true

  alias Camelot.Board.Column

  @now ~U[2030-01-01 12:00:00.000000Z]
  @future ~U[2030-01-02 12:00:00.000000Z]
  @past ~U[2029-12-31 12:00:00.000000Z]

  defp task(attrs), do: Map.merge(%{stage: :todo, state: :queued, start_at: nil}, attrs)

  describe "stage_for/2 with a future start_at" do
    for stage <- [:todo, :planning, :executing] do
      test "queued #{stage} card waits in :todo" do
        task = task(%{stage: unquote(stage), start_at: @future})
        assert Column.stage_for(task, @now) == :todo
      end
    end

    for state <- [:in_progress, :paused, :error, :waiting_for_input] do
      test "#{state} executing card keeps its stage" do
        task = task(%{stage: :executing, state: unquote(state), start_at: @future})
        assert Column.stage_for(task, @now) == :executing
      end
    end

    for stage <- [:pr, :done] do
      test "#{stage} card keeps its stage" do
        task = task(%{stage: unquote(stage), start_at: @future})
        assert Column.stage_for(task, @now) == unquote(stage)
      end
    end
  end

  describe "stage_for/2 without a future start_at" do
    test "nil start_at keeps the real stage" do
      assert Column.stage_for(task(%{stage: :executing}), @now) == :executing
    end

    test "past start_at keeps the real stage" do
      task = task(%{stage: :planning, start_at: @past})
      assert Column.stage_for(task, @now) == :planning
    end

    test "start_at equal to now keeps the real stage" do
      task = task(%{stage: :executing, start_at: @now})
      assert Column.stage_for(task, @now) == :executing
    end
  end

  describe "next_start_at/2" do
    test "returns the earliest waiting start_at" do
      tasks = [
        task(%{start_at: @future}),
        task(%{start_at: DateTime.add(@future, -3600)}),
        task(%{start_at: @past}),
        task(%{})
      ]

      assert Column.next_start_at(tasks, @now) == DateTime.add(@future, -3600)
    end

    test "is nil when nothing waits" do
      assert Column.next_start_at([task(%{start_at: @past})], @now) == nil
    end
  end
end
