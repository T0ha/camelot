defmodule Camelot.Scheduling.GateTest do
  use ExUnit.Case, async: true

  alias Camelot.Agents.RunWindow
  alias Camelot.Agents.UsagePolicy
  alias Camelot.Agents.UsageSnapshot
  alias Camelot.Board.Task
  alias Camelot.Scheduling.Gate

  # Monday 12:00 UTC.
  @now ~U[2026-10-19 12:00:00Z]
  @reset ~U[2026-10-23 08:00:00Z]
  @hour 3_600_000

  defp task(attrs \\ %{}) do
    struct(
      %Task{
        weekly_cap_override: nil,
        windows_override: nil,
        ignore_limits: false,
        start_at: nil,
        deadline_at: nil
      },
      attrs
    )
  end

  defp policy(attrs), do: struct(%UsagePolicy{weekly_cap_percent: nil, windows: []}, attrs)

  defp snapshot(percent) do
    %UsageSnapshot{window: :weekly, used_percent: percent, resets_at: @reset, source: :cli}
  end

  defp window(start_minute, end_minute) do
    %RunWindow{start_minute: start_minute, end_minute: end_minute}
  end

  # Monday 09:00–10:00, which excludes @now.
  defp morning, do: [window(540, 600)]
  # Monday 11:00–13:00, which contains @now.
  defp midday, do: [window(660, 780)]

  test "no policy, no snapshot, nothing pinned runs" do
    assert Gate.decide(task(), nil, nil, @hour, @now) == :run
  end

  describe "1. start_at" do
    test "a future start_at waits until then, even when everything else passes" do
      start_at = DateTime.add(@now, 600, :second)

      assert Gate.decide(task(start_at: start_at, ignore_limits: true), nil, nil, @hour, @now) ==
               {:wait, :start_at, start_at}
    end

    test "a past start_at no longer gates" do
      assert Gate.decide(task(start_at: DateTime.add(@now, -1, :second)), nil, nil, @hour, @now) ==
               :run
    end
  end

  describe "2. deadline" do
    test "is promoted once the deadline is within two estimated runs, bypassing cap and windows" do
      deadline = DateTime.add(@now, 90 * 60, :second)
      t = task(deadline_at: deadline)
      p = policy(weekly_cap_percent: 50, windows: morning())

      assert Gate.decide(t, p, snapshot(80.0), @hour, @now) == {:run, :promoted}
    end

    test "is at risk when the estimated run can no longer finish in time" do
      deadline = DateTime.add(@now, 30 * 60, :second)

      assert Gate.decide(task(deadline_at: deadline), nil, nil, @hour, @now) == {:run, :at_risk}
    end

    test "a passed deadline still runs, at risk" do
      deadline = DateTime.add(@now, -60, :second)

      assert Gate.decide(task(deadline_at: deadline), nil, nil, @hour, @now) == {:run, :at_risk}
    end

    test "a far deadline does not bypass anything" do
      deadline = DateTime.add(@now, 86_400, :second)
      p = policy(weekly_cap_percent: 50)

      assert Gate.decide(task(deadline_at: deadline), p, snapshot(80.0), @hour, @now) ==
               {:wait, :cap, @reset}
    end

    test "start_at still comes first" do
      start_at = DateTime.add(@now, 60, :second)
      deadline = DateTime.add(@now, 120, :second)

      assert Gate.decide(task(start_at: start_at, deadline_at: deadline), nil, nil, @hour, @now) ==
               {:wait, :start_at, start_at}
    end
  end

  describe "3. ignore_limits" do
    test "runs over the cap, flagged as cutting into the reserve" do
      p = policy(weekly_cap_percent: 50)

      assert Gate.decide(task(ignore_limits: true), p, snapshot(60.0), @hour, @now) ==
               {:run, :reserve_risk}
    end

    test "runs outside windows without a flag when under the cap" do
      p = policy(weekly_cap_percent: 50, windows: morning())

      assert Gate.decide(task(ignore_limits: true), p, snapshot(10.0), @hour, @now) == :run
    end
  end

  describe "4. weekly cap" do
    test "waits until the reset when used% reaches the cap" do
      p = policy(weekly_cap_percent: 50)

      assert Gate.decide(task(), p, snapshot(50.0), @hour, @now) == {:wait, :cap, @reset}
    end

    test "runs below the cap" do
      assert Gate.decide(task(), policy(weekly_cap_percent: 50), snapshot(49.9), @hour, @now) ==
               :run
    end

    test "the task override wins over the policy cap, in both directions" do
      p = policy(weekly_cap_percent: 50)

      assert Gate.decide(task(weekly_cap_override: 90), p, snapshot(60.0), @hour, @now) == :run

      assert Gate.decide(task(weekly_cap_override: 20), nil, snapshot(30.0), @hour, @now) ==
               {:wait, :cap, @reset}
    end

    test "no snapshot or no cap passes" do
      assert Gate.decide(task(), policy(weekly_cap_percent: 1), nil, @hour, @now) == :run
      assert Gate.decide(task(), policy(weekly_cap_percent: nil), snapshot(99.0), @hour, @now) == :run
    end
  end

  describe "5. run windows" do
    test "outside every window waits until the next one opens" do
      p = policy(windows: morning())

      assert Gate.decide(task(), p, nil, @hour, @now) ==
               {:wait, :window, ~U[2026-10-26 09:00:00Z]}
    end

    test "inside a window runs" do
      assert Gate.decide(task(), policy(windows: midday()), nil, @hour, @now) == :run
    end

    test "a task override replaces the policy windows" do
      p = policy(windows: midday())

      assert {:wait, :window, _} = Gate.decide(task(windows_override: morning()), p, nil, @hour, @now)
    end

    test "an empty override lifts the policy's restriction, nil inherits it" do
      p = policy(windows: morning())

      assert Gate.decide(task(windows_override: []), p, nil, @hour, @now) == :run
      assert {:wait, :window, _} = Gate.decide(task(windows_override: nil), p, nil, @hour, @now)
    end

    test "the cap is checked before windows" do
      p = policy(weekly_cap_percent: 10, windows: morning())

      assert Gate.decide(task(), p, snapshot(20.0), @hour, @now) == {:wait, :cap, @reset}
    end
  end
end
