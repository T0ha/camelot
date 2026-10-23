defmodule Camelot.Scheduling.Gate do
  @moduledoc """
  Decides, at dispatch time, whether a queued card may start now.

  Pure: the task, its creator's `Camelot.Agents.UsagePolicy` for the
  agent (or `nil`), the effective weekly `Camelot.Agents.UsageSnapshot`
  for the credential it would run on (or `nil`), the estimated run
  length and the clock in; a decision out. Loading those inputs is
  `Camelot.Scheduling.Planner`'s job.

  The rules, first match wins:

    1. `start_at` in the future → wait until `start_at`.
    2. A deadline close enough that waiting risks missing it → run,
       bypassing cap and windows. "Close enough" is two estimated runs
       before the deadline: one for the run itself, one of slack for
       the runner-slot queue. `:at_risk` once even an immediate start
       is estimated to finish late, `:promoted` before that.
    3. `ignore_limits` → run, flagged `:reserve_risk` when the weekly
       snapshot is already at or over the cap.
    4. Weekly cap (task override, else policy) reached → wait until
       the snapshot's `resets_at`. No snapshot or no cap passes.
    5. Run windows (task override when not nil, else policy) exclude
       now → wait until the next window opens. `[]` always passes.
    6. Otherwise → run.

  Running sessions are never stopped — this only gates new dispatches.
  """

  alias Camelot.Agents.UsagePolicy
  alias Camelot.Board.Task
  alias Camelot.Scheduling.Windows

  @type flag :: :promoted | :reserve_risk | :at_risk
  @type reason :: :start_at | :cap | :window
  @type decision :: :run | {:run, flag()} | {:wait, reason(), DateTime.t()}

  @typedoc "Anything carrying a weekly `used_percent` and `resets_at`."
  @type snapshot :: %{used_percent: float(), resets_at: DateTime.t()} | nil

  @doc "Decides what to do with `task` right now — see the moduledoc."
  @spec decide(Task.t(), UsagePolicy.t() | nil, snapshot(), non_neg_integer(), DateTime.t()) ::
          decision()
  def decide(task, policy, snapshot, estimate_ms, now) do
    with :next <- check_start(task, now),
         :next <- check_deadline(task, estimate_ms, now),
         :next <- check_ignore_limits(task, policy, snapshot),
         :next <- check_cap(task, policy, snapshot) do
      check_windows(task, policy, now)
    end
  end

  @doc """
  The weekly cap that applies to `task`: its own override, else the
  policy's, else `nil`.
  """
  @spec effective_cap(Task.t(), UsagePolicy.t() | nil) :: 1..100 | nil
  def effective_cap(%{weekly_cap_override: nil}, policy), do: policy_cap(policy)
  def effective_cap(%{weekly_cap_override: cap}, _policy), do: cap

  @doc """
  The run windows that apply to `task`: its own override when set
  (even `[]`, which lifts the restriction), else the policy's.
  """
  @spec effective_windows(Task.t(), UsagePolicy.t() | nil) :: list()
  def effective_windows(%{windows_override: nil}, policy), do: policy_windows(policy)
  def effective_windows(%{windows_override: windows}, _policy), do: windows

  @doc "Whether `snapshot` is at or over `task`'s effective cap."
  @spec over_cap?(Task.t(), UsagePolicy.t() | nil, snapshot()) :: boolean()
  def over_cap?(task, policy, snapshot) do
    reached?(effective_cap(task, policy), snapshot)
  end

  defp check_start(%{start_at: nil}, _now), do: :next

  defp check_start(%{start_at: start_at}, now) do
    start_decision(DateTime.after?(start_at, now), start_at)
  end

  defp start_decision(true, start_at), do: {:wait, :start_at, start_at}
  defp start_decision(false, _start_at), do: :next

  defp check_deadline(%{deadline_at: nil}, _estimate_ms, _now), do: :next

  defp check_deadline(%{deadline_at: deadline_at}, estimate_ms, now) do
    deadline_decision(
      DateTime.diff(deadline_at, now, :millisecond),
      estimate_ms
    )
  end

  defp deadline_decision(left_ms, estimate_ms) when left_ms < estimate_ms, do: {:run, :at_risk}
  defp deadline_decision(left_ms, estimate_ms) when left_ms <= 2 * estimate_ms, do: {:run, :promoted}
  defp deadline_decision(_left_ms, _estimate_ms), do: :next

  defp check_ignore_limits(%{ignore_limits: true} = task, policy, snapshot) do
    pinned_decision(over_cap?(task, policy, snapshot))
  end

  defp check_ignore_limits(_task, _policy, _snapshot), do: :next

  defp pinned_decision(true), do: {:run, :reserve_risk}
  defp pinned_decision(false), do: :run

  defp check_cap(task, policy, snapshot) do
    cap_decision(over_cap?(task, policy, snapshot), snapshot)
  end

  defp cap_decision(true, %{resets_at: resets_at}), do: {:wait, :cap, resets_at}
  defp cap_decision(false, _snapshot), do: :next

  defp check_windows(task, policy, now) do
    task
    |> effective_windows(policy)
    |> window_decision(now)
  end

  defp window_decision([], _now), do: :run

  defp window_decision(windows, now) do
    inside_decision(Windows.inside?(windows, now), windows, now)
  end

  defp inside_decision(true, _windows, _now), do: :run
  defp inside_decision(false, windows, now), do: {:wait, :window, Windows.next_start(windows, now)}

  defp policy_cap(%UsagePolicy{weekly_cap_percent: cap}), do: cap
  defp policy_cap(nil), do: nil

  defp policy_windows(%UsagePolicy{windows: windows}), do: windows
  defp policy_windows(nil), do: []

  defp reached?(nil, _snapshot), do: false
  defp reached?(_cap, nil), do: false
  defp reached?(cap, %{used_percent: used}), do: used >= cap
end
