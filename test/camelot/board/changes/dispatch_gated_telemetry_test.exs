defmodule Camelot.Board.Changes.DispatchGatedTelemetryTest do
  @moduledoc """
  `task_gated` must report a change in what scheduling does with a
  card, not restate it on every one-minute dispatch tick.
  """
  use Camelot.DataCase, async: false

  alias Camelot.Agents.UsagePolicy
  alias Camelot.Agents.UsageSnapshots
  alias Camelot.Board.Changes.DispatchTasks
  alias Camelot.Board.Task
  alias Camelot.Projects.Project

  setup_all {PostHog.Test, :set_posthog_shared}

  setup do
    user = user!()

    {:ok, project} =
      Ash.create(Project, %{
        name: "gated-#{System.unique_integer([:positive])}",
        path: "/tmp/gated"
      })

    {:ok, task} =
      Ash.create(Task, %{
        title: "gated",
        project_id: project.id,
        creator_id: user.id,
        agent_id: agent!("claude_code").id
      })

    %{user: user, task: task}
  end

  defp gated_events(task) do
    Enum.filter(
      PostHog.Test.all_captured(),
      &(&1.event == "task_gated" and &1.properties[:data_id] == task.id)
    )
  end

  defp gate!(task), do: DispatchTasks.apply_gate([Ash.get!(Task, task.id)], DateTime.utc_now())

  test "reports a reason once, and again only when it changes", %{user: user, task: task} do
    Ash.create!(UsagePolicy, %{user_id: user.id, agent_id: task.agent_id, weekly_cap_percent: 10}, action: :upsert)

    {:ok, _} =
      UsageSnapshots.record(
        user.id,
        :claude_api_key,
        [%{window: :weekly, used_percent: 50.0, resets_at: DateTime.add(DateTime.utc_now(), 1, :day)}],
        :cli
      )

    assert gate!(task) == []
    assert gate!(task) == []

    assert [%{distinct_id: distinct_id, properties: %{reason: :cap}}] = gated_events(task)
    assert distinct_id == user.id

    Ash.update!(Ash.get!(Task, task.id), %{start_at: DateTime.add(DateTime.utc_now(), 3600, :second)},
      action: :set_schedule
    )

    gate!(task)

    assert task |> gated_events() |> Enum.map(& &1.properties.reason) |> Enum.sort() ==
             [:cap, :start_at]
  end

  test "a card nothing gates is not reported", %{task: task} do
    assert [%Task{}] = gate!(task)
    assert gated_events(task) == []
  end
end
