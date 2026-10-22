defmodule Camelot.TimeZoneTest do
  use ExUnit.Case, async: true

  alias Camelot.Agents.RunWindow
  alias Camelot.TimeZone

  # Berlin is on CEST (+02:00) until 2026-10-25.
  @now ~U[2026-10-19 10:00:00Z]

  describe "local_input_to_utc/2" do
    test "converts a datetime-local value from the user's zone to UTC" do
      assert TimeZone.local_input_to_utc("2026-10-19T14:00", "Europe/Berlin") ==
               {:ok, ~U[2026-10-19 12:00:00.000000Z]}
    end

    test "accepts seconds" do
      assert {:ok, ~U[2026-10-19 12:00:30.000000Z]} =
               TimeZone.local_input_to_utc("2026-10-19T14:00:30", "Europe/Berlin")
    end

    test "blank is nil" do
      assert TimeZone.local_input_to_utc("", "Europe/Berlin") == {:ok, nil}
      assert TimeZone.local_input_to_utc(nil, "Europe/Berlin") == {:ok, nil}
    end

    test "garbage is an error" do
      assert {:error, _} = TimeZone.local_input_to_utc("tomorrow", "Etc/UTC")
    end

    test "a time skipped by a DST jump resolves to just after the gap" do
      # 2026-03-29 02:30 does not exist in Berlin.
      assert {:ok, ~U[2026-03-29 01:00:00.000000Z]} =
               TimeZone.local_input_to_utc("2026-03-29T02:30", "Europe/Berlin")
    end
  end

  describe "to_local_input/2" do
    test "renders a UTC datetime as a datetime-local value in the user's zone" do
      assert TimeZone.to_local_input(~U[2026-10-19 12:00:00Z], "Europe/Berlin") ==
               "2026-10-19T14:00"
    end

    test "nil is blank" do
      assert TimeZone.to_local_input(nil, "Europe/Berlin") == ""
    end
  end

  describe "format/2" do
    test "names the local time and zone" do
      assert TimeZone.format(~U[2026-10-19 12:00:00Z], "Europe/Berlin") ==
               "Mon 19 Oct 14:00 CEST"
    end

    test "nil is a dash" do
      assert TimeZone.format(nil, "Etc/UTC") == "—"
    end
  end

  describe "rows_to_windows/3" do
    test "converts local weekday rows into UTC minute-of-week windows" do
      rows = [%{days: [1, 3], from: "09:00", to: "17:00"}]

      assert TimeZone.rows_to_windows(rows, "Europe/Berlin", @now) == [
               %RunWindow{start_minute: 420, end_minute: 900},
               %RunWindow{start_minute: 2 * 1440 + 420, end_minute: 2 * 1440 + 900}
             ]
    end

    test "a local Monday early-morning window wraps back into Sunday UTC" do
      rows = [%{days: [1], from: "01:00", to: "03:00"}]

      assert TimeZone.rows_to_windows(rows, "Europe/Berlin", @now) == [
               %RunWindow{start_minute: 6 * 1440 + 23 * 60, end_minute: 60}
             ]
    end

    test "a to-time before the from-time runs past midnight" do
      rows = [%{days: [7], from: "22:00", to: "06:00"}]

      assert TimeZone.rows_to_windows(rows, "Etc/UTC", @now) == [
               %RunWindow{start_minute: 6 * 1440 + 22 * 60, end_minute: 6 * 60}
             ]
    end

    test "rows with no days or equal times are dropped" do
      rows = [%{days: [], from: "09:00", to: "17:00"}, %{days: [1], from: "09:00", to: "09:00"}]

      assert TimeZone.rows_to_windows(rows, "Etc/UTC", @now) == []
    end
  end

  describe "windows_to_rows/3" do
    test "round-trips, grouping days that share times" do
      rows = [
        %{days: [1, 2, 3, 4, 5], from: "09:00", to: "17:00"},
        %{days: [6], from: "22:00", to: "02:00"}
      ]

      windows = TimeZone.rows_to_windows(rows, "Europe/Berlin", @now)

      assert TimeZone.windows_to_rows(windows, "Europe/Berlin", @now) == rows
    end

    test "no windows, no rows" do
      assert TimeZone.windows_to_rows([], "Etc/UTC", @now) == []
    end
  end
end
