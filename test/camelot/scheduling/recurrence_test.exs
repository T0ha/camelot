defmodule Camelot.Scheduling.RecurrenceTest do
  use ExUnit.Case, async: true

  alias Camelot.Scheduling.Recurrence

  defp rule(attrs) do
    Map.merge(
      %{
        frequency: :daily,
        interval: 1,
        weekdays: [],
        day_of_month: nil,
        time_of_day: ~T[09:00:00],
        time_zone: "Etc/UTC",
        inserted_at: ~U[2030-01-01 00:00:00Z]
      },
      attrs
    )
  end

  describe "daily" do
    test "today when the time is still ahead" do
      assert Recurrence.next_occurrence(rule(%{}), ~U[2030-01-07 08:00:00Z]) ==
               {:ok, ~U[2030-01-07 09:00:00Z]}
    end

    test "tomorrow once today's time has passed" do
      assert Recurrence.next_occurrence(rule(%{}), ~U[2030-01-07 10:00:00Z]) ==
               {:ok, ~U[2030-01-08 09:00:00Z]}
    end

    test "is strictly after the given instant" do
      assert Recurrence.next_occurrence(rule(%{}), ~U[2030-01-07 09:00:00Z]) ==
               {:ok, ~U[2030-01-08 09:00:00Z]}
    end

    test "every 2 days counts from the rule's creation date" do
      every_other = rule(%{interval: 2})

      # 2030-01-01 + 2n: the 7th is off, the 9th is on.
      assert Recurrence.next_occurrence(every_other, ~U[2030-01-07 08:00:00Z]) ==
               {:ok, ~U[2030-01-07 09:00:00Z]}

      assert Recurrence.next_occurrence(every_other, ~U[2030-01-07 10:00:00Z]) ==
               {:ok, ~U[2030-01-09 09:00:00Z]}
    end
  end

  describe "weekly" do
    test "the next listed weekday" do
      # 2030-01-07 is a Monday.
      mon_thu = rule(%{frequency: :weekly, weekdays: [4, 1]})

      assert Recurrence.next_occurrence(mon_thu, ~U[2030-01-07 10:00:00Z]) ==
               {:ok, ~U[2030-01-10 09:00:00Z]}

      assert Recurrence.next_occurrence(mon_thu, ~U[2030-01-10 10:00:00Z]) ==
               {:ok, ~U[2030-01-14 09:00:00Z]}
    end

    test "every 2 weeks skips the off week" do
      # Created in the week of Mon 2029-12-31, so that week and the
      # week of Mon 2030-01-14 are on; the week of the 7th is off.
      fortnightly = rule(%{frequency: :weekly, interval: 2, weekdays: [1]})

      assert Recurrence.next_occurrence(fortnightly, ~U[2030-01-01 10:00:00Z]) ==
               {:ok, ~U[2030-01-14 09:00:00Z]}
    end

    test "no weekdays is an invalid rule" do
      assert Recurrence.next_occurrence(
               rule(%{frequency: :weekly, weekdays: []}),
               ~U[2030-01-07 10:00:00Z]
             ) == {:error, :invalid_rule}
    end
  end

  describe "monthly" do
    test "the given day of the month" do
      on_15th = rule(%{frequency: :monthly, day_of_month: 15})

      assert Recurrence.next_occurrence(on_15th, ~U[2030-01-07 10:00:00Z]) ==
               {:ok, ~U[2030-01-15 09:00:00Z]}

      assert Recurrence.next_occurrence(on_15th, ~U[2030-01-15 10:00:00Z]) ==
               {:ok, ~U[2030-02-15 09:00:00Z]}
    end

    test "day 31 falls on the last day of a shorter month" do
      on_31st = rule(%{frequency: :monthly, day_of_month: 31})

      assert Recurrence.next_occurrence(on_31st, ~U[2030-01-31 10:00:00Z]) ==
               {:ok, ~U[2030-02-28 09:00:00Z]}

      assert Recurrence.next_occurrence(on_31st, ~U[2030-02-28 10:00:00Z]) ==
               {:ok, ~U[2030-03-31 09:00:00Z]}
    end

    test "every 3 months counts from the rule's creation month" do
      quarterly = rule(%{frequency: :monthly, interval: 3, day_of_month: 1})

      assert Recurrence.next_occurrence(quarterly, ~U[2030-01-01 10:00:00Z]) ==
               {:ok, ~U[2030-04-01 09:00:00Z]}
    end

    test "no day of month is an invalid rule" do
      assert Recurrence.next_occurrence(
               rule(%{frequency: :monthly, day_of_month: nil}),
               ~U[2030-01-07 10:00:00Z]
             ) == {:error, :invalid_rule}
    end
  end

  describe "time zones" do
    test "the time is local to the rule's zone" do
      tokyo = rule(%{time_zone: "Asia/Tokyo"})

      # 09:00 JST is 00:00 UTC.
      assert Recurrence.next_occurrence(tokyo, ~U[2030-01-07 01:00:00Z]) ==
               {:ok, ~U[2030-01-08 00:00:00Z]}
    end

    test "the local date decides the day, not the UTC one" do
      # 23:30 UTC on Sunday is already Monday 08:30 in Tokyo.
      monday = rule(%{frequency: :weekly, weekdays: [1], time_zone: "Asia/Tokyo"})

      assert Recurrence.next_occurrence(monday, ~U[2030-01-06 23:30:00Z]) ==
               {:ok, ~U[2030-01-07 00:00:00Z]}
    end

    test "stays at the same wall-clock time across a DST change" do
      berlin = rule(%{time_zone: "Europe/Berlin"})

      # CET (+1) before 2030-03-31, CEST (+2) after.
      assert Recurrence.next_occurrence(berlin, ~U[2030-03-30 09:00:00Z]) ==
               {:ok, ~U[2030-03-31 07:00:00Z]}
    end

    test "a time inside the spring-forward gap runs right after it" do
      # 02:30 does not exist in Berlin on 2030-03-31.
      gap = rule(%{time_zone: "Europe/Berlin", time_of_day: ~T[02:30:00]})

      assert Recurrence.next_occurrence(gap, ~U[2030-03-30 12:00:00Z]) ==
               {:ok, ~U[2030-03-31 01:00:00Z]}
    end

    test "a time inside the fall-back overlap runs at its first occurrence" do
      # 02:30 happens twice in Berlin on 2030-10-27; the first is CEST.
      overlap = rule(%{time_zone: "Europe/Berlin", time_of_day: ~T[02:30:00]})

      assert Recurrence.next_occurrence(overlap, ~U[2030-10-26 12:00:00Z]) ==
               {:ok, ~U[2030-10-27 00:30:00Z]}
    end
  end

  test "a rule without a creation date anchors on the given instant" do
    fresh = rule(%{interval: 2, inserted_at: nil})

    assert Recurrence.next_occurrence(fresh, ~U[2030-01-07 10:00:00Z]) ==
             {:ok, ~U[2030-01-09 09:00:00Z]}
  end
end
