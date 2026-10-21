defmodule Camelot.Scheduling.Planner do
  @moduledoc """
  Feeds `Camelot.Scheduling.Gate` for a batch of queued cards and
  orders whatever may run.

  Shared by the dispatcher (`Camelot.Board.Changes.DispatchTasks`) and
  the board badges (`Camelot.Board.Task.Calculations.ScheduledWait`),
  so a badge never disagrees with what dispatch does. Every input is
  loaded once per call, not once per card:

    * the creators' `Camelot.Agents.UsagePolicy` rows — one query;
    * the effective weekly snapshot per creator + credential kind —
      `Camelot.Agents.UsageSnapshots.batch_latest/2`;
    * a duration estimate per agent + stage —
      `Camelot.Scheduling.DurationEstimate.estimates/1`.

  A card's credential kind is its agent's first
  `required_credential_kinds` entry, the one `TaskRunner` attributes
  usage to.
  """

  alias Camelot.Agents.Agent
  alias Camelot.Agents.UsagePolicy
  alias Camelot.Agents.UsageSnapshots
  alias Camelot.Board.Task
  alias Camelot.Scheduling.DurationEstimate
  alias Camelot.Scheduling.Gate

  require Ash.Query

  @promoted_flags [:promoted, :at_risk]

  @doc """
  A gate decision for every task. Only the tasks' own attributes are
  read; agents, policies, snapshots and estimates are loaded here.
  """
  @spec decide_all([Task.t()], DateTime.t()) :: [{Task.t(), Gate.decision()}]
  def decide_all([], _now), do: []

  def decide_all(tasks, now) do
    kinds = credential_kinds(tasks)
    policies = load_policies(tasks)

    snapshots =
      tasks
      |> Enum.map(&snapshot_key(&1, kinds))
      |> Enum.reject(&is_nil/1)
      |> UsageSnapshots.batch_latest(now)

    estimates = tasks |> Enum.map(&estimate_key/1) |> DurationEstimate.estimates()

    Enum.map(tasks, fn task ->
      {task,
       Gate.decide(
         task,
         Map.get(policies, {task.creator_id, task.agent_id}),
         Map.get(snapshots, snapshot_key(task, kinds)),
         Map.fetch!(estimates, estimate_key(task)),
         now
       )}
    end)
  end

  @doc """
  The tasks allowed to run, in dispatch order: deadline-promoted (and
  at-risk) cards first, then by nearest `deadline_at` (cards without
  one last), then by `priority`, highest first. Sorting is stable, so
  ties keep their incoming order.
  """
  @spec runnable([{Task.t(), Gate.decision()}]) :: [Task.t()]
  def runnable(decisions) do
    decisions
    |> Enum.reject(&match?({_task, {:wait, _reason, _until}}, &1))
    |> Enum.sort_by(fn {task, decision} -> sort_key(task, decision) end)
    |> Enum.map(&elem(&1, 0))
  end

  @doc """
  The creator's policy for `task`'s agent and the effective weekly
  snapshot of the credential it would run on — what the task page
  needs to warn before a card cuts into the reserve.
  """
  @spec inputs(Task.t(), DateTime.t()) :: {UsagePolicy.t() | nil, Gate.snapshot()}
  def inputs(task, now) do
    policy = task |> List.wrap() |> load_policies() |> Map.get({task.creator_id, task.agent_id})

    snapshot =
      case snapshot_key(task, credential_kinds([task])) do
        nil -> nil
        {user_id, kind} -> UsageSnapshots.effective_weekly(user_id, kind, now)
      end

    {policy, snapshot}
  end

  defp load_policies(tasks) do
    creator_ids = tasks |> Enum.map(& &1.creator_id) |> Enum.uniq()

    UsagePolicy
    |> Ash.Query.filter(user_id in ^creator_ids)
    |> Ash.read!(authorize?: false)
    |> Map.new(&{{&1.user_id, &1.agent_id}, &1})
  end

  # The agent's primary credential kind, per agent id. Read here rather
  # than off a preloaded `task.agent`: inside a calculation Ash may
  # hand over an agent with only some attributes selected.
  defp credential_kinds(tasks) do
    agent_ids = tasks |> Enum.map(& &1.agent_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    Agent
    |> Ash.Query.filter(id in ^agent_ids)
    |> Ash.read!(authorize?: false)
    |> Map.new(&{&1.id, primary_kind(&1)})
  end

  defp primary_kind(%Agent{required_credential_kinds: [kind | _]}), do: kind
  defp primary_kind(_agent), do: nil

  defp snapshot_key(%Task{creator_id: creator_id, agent_id: agent_id}, kinds) do
    case Map.get(kinds, agent_id) do
      nil -> nil
      kind -> {creator_id, kind}
    end
  end

  defp estimate_key(%Task{agent_id: agent_id, stage: stage}) do
    {agent_id, DurationEstimate.next_stage(stage)}
  end

  defp sort_key(task, decision) do
    {promotion_rank(decision), deadline_rank(task.deadline_at), -task.priority}
  end

  defp promotion_rank({:run, flag}) when flag in @promoted_flags, do: 0
  defp promotion_rank(_decision), do: 1

  defp deadline_rank(nil), do: {1, 0}
  defp deadline_rank(deadline_at), do: {0, DateTime.to_unix(deadline_at, :microsecond)}
end
