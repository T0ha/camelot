defmodule Camelot.Scheduling.WindowsTest do
  use ExUnit.Case, async: true

  alias Camelot.Agents.RunWindow
  alias Camelot.Scheduling.Windows

  # 2026-10-19 is a Monday.
  defp at(day_offset, hour, minute) do
    ~U[2026-10-19 00:00:00Z]
    |> DateTime.add(day_offset * 86_400 + hour * 3600 + minute * 60, :second)
  end

  defp window(start_minute, end_minute) do
    %RunWindow{start_minute: start_minute, end_minute: end_minute}
  end

  describe "minute_of_week/1" do
    test "Monday 00:00 UTC is 0, Sunday 23:59 is the last minute" do
      assert Windows.minute_of_week(at(0, 0, 0)) == 0
      assert Windows.minute_of_week(at(0, 9, 30)) == 570
      assert Windows.minute_of_week(at(6, 23, 59)) == 10_079
    end

    test "ignores seconds" do
      assert Windows.minute_of_week(DateTime.add(at(1, 0, 0), 59, :second)) == 1440
    end
  end

  describe "inside?/2" do
    test "start is inclusive and end is exclusive" do
      windows = [window(540, 1020)]

      refute Windows.inside?(windows, at(0, 8, 59))
      assert Windows.inside?(windows, at(0, 9, 0))
      assert Windows.inside?(windows, at(0, 16, 59))
      refute Windows.inside?(windows, at(0, 17, 0))
    end

    test "a window whose end is before its start wraps past Sunday into Monday" do
      # Sunday 22:00 → Monday 06:00.
      windows = [window(6 * 1440 + 22 * 60, 6 * 60)]

      assert Windows.inside?(windows, at(6, 23, 0))
      assert Windows.inside?(windows, at(0, 5, 59))
      refute Windows.inside?(windows, at(0, 6, 0))
      refute Windows.inside?(windows, at(6, 21, 59))
    end

    test "any matching window is enough" do
      windows = [window(0, 60), window(1440, 1500)]

      assert Windows.inside?(windows, at(1, 0, 30))
      refute Windows.inside?(windows, at(2, 0, 30))
    end

    test "no windows means nothing is inside" do
      refute Windows.inside?([], at(0, 0, 0))
    end
  end

  describe "next_start/2" do
    test "the soonest upcoming window start" do
      windows = [window(1440 + 540, 1440 + 600), window(540, 600)]

      assert Windows.next_start(windows, at(0, 10, 0)) == at(1, 9, 0)
      assert Windows.next_start(windows, at(0, 8, 15)) == at(0, 9, 0)
    end

    test "crosses the week edge" do
      # Only a Monday 09:00 window; it is Sunday 20:00.
      assert Windows.next_start([window(540, 600)], at(6, 20, 0)) == at(7, 9, 0)
    end

    test "drops seconds from now" do
      now = DateTime.add(at(0, 8, 0), 42, :second)
      assert Windows.next_start([window(540, 600)], now) == at(0, 9, 0)
    end

    test "nil without windows" do
      assert Windows.next_start([], at(0, 0, 0)) == nil
    end
  end
end
