defmodule Camelot.Board.RecurrenceRuleTest do
  use Camelot.DataCase, async: true

  alias Camelot.Agents.Session
  alias Camelot.Board.RecurrenceRule
  alias Camelot.Board.Task
  alias Camelot.Projects.Project

  require Ash.Query

  setup do
    {:ok, project} =
      Ash.create(Project, %{
        name: "recur-#{System.unique_integer([:positive])}",
        path: "/tmp/recur-#{System.unique_integer([:positive])}"
      })

    %{project: project, user: user!(), agent: agent!("claude_code")}
  end

  defp task!(ctx, attrs \\ %{}) do
    Ash.create!(
      Task,
      Map.merge(
        %{
          title: "recurring",
          description: "do the thing",
          project_id: ctx.project.id,
          creator_id: ctx.user.id,
          agent_id: ctx.agent.id
        },
        attrs
      )
    )
  end

  defp rule!(task, ctx, attrs \\ %{}) do
    Ash.create!(
      RecurrenceRule,
      Map.merge(
        %{
          frequency: :daily,
          time_of_day: ~T[09:00:00],
          time_zone: "Europe/Berlin",
          task_id: task.id,
          creator_id: ctx.user.id
        },
        attrs
      )
    )
  end

  defp finish!(task), do: Ash.update!(task, %{}, action: :cancel)

  defp series(rule) do
    Task
    |> Ash.Query.filter(recurrence_rule_id == ^rule.id)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!()
  end

  # The trigger's `where` is what AshOban runs to pick the rules to
  # spawn for, so apply that same expression rather than restating it.
  defp due_rule_ids do
    trigger = AshOban.Info.oban_trigger(RecurrenceRule, :spawn_next)

    RecurrenceRule
    |> Ash.Query.do_filter(trigger.where)
    |> Ash.read!()
    |> Enum.map(& &1.id)
  end

  defp within_a_day?(datetime) do
    now = DateTime.utc_now()

    DateTime.after?(datetime, now) and
      DateTime.before?(datetime, DateTime.add(now, 86_400, :second))
  end

  describe ":create" do
    test "computes next_run_at and joins the card to the series", ctx do
      task = task!(ctx)
      rule = rule!(task, ctx)

      assert rule.enabled
      assert rule.project_id == ctx.project.id
      assert within_a_day?(rule.next_run_at)

      local = DateTime.shift_zone!(rule.next_run_at, "Europe/Berlin")
      assert {local.hour, local.minute} == {9, 0}

      task = Ash.get!(Task, task.id)
      assert task.recurrence_rule_id == rule.id
      assert DateTime.compare(task.start_at, rule.next_run_at) == :eq
    end

    test "leaves the start of a card that already ran alone", ctx do
      task = task!(ctx)
      Ash.create!(Session, %{agent_id: ctx.agent.id, task_id: task.id})
      task = Ash.update!(task, %{}, action: :begin_work)

      rule = rule!(task, ctx)

      task = Ash.get!(Task, task.id)
      assert task.recurrence_rule_id == rule.id
      assert task.start_at == nil
    end

    test "rejects an unknown time zone", ctx do
      task = task!(ctx)

      assert {:error, _} =
               Ash.create(RecurrenceRule, %{
                 frequency: :daily,
                 time_of_day: ~T[09:00:00],
                 time_zone: "Mars/Olympus",
                 task_id: task.id,
                 creator_id: ctx.user.id
               })
    end

    test "rejects a weekly rule without weekdays", ctx do
      task = task!(ctx)

      assert {:error, _} =
               Ash.create(RecurrenceRule, %{
                 frequency: :weekly,
                 weekdays: [],
                 time_of_day: ~T[09:00:00],
                 time_zone: "Etc/UTC",
                 task_id: task.id,
                 creator_id: ctx.user.id
               })

      assert Ash.get!(Task, task.id).recurrence_rule_id == nil
    end
  end

  describe ":update" do
    test "moves the upcoming card to the new time", ctx do
      task = task!(ctx)
      rule = rule!(task, ctx)

      rule = Ash.update!(rule, %{time_of_day: ~T[18:30:00]})

      local = DateTime.shift_zone!(rule.next_run_at, "Europe/Berlin")
      assert {local.hour, local.minute} == {18, 30}

      task = Ash.get!(Task, task.id)
      assert DateTime.compare(task.start_at, rule.next_run_at) == :eq
    end
  end

  describe ":disable" do
    test "turns the series off and keeps the card", ctx do
      task = task!(ctx)
      rule = rule!(task, ctx)

      rule = Ash.update!(rule, %{}, action: :disable)

      refute rule.enabled
      assert rule.next_run_at == nil
      assert Ash.get!(Task, task.id).recurrence_rule_id == rule.id
    end
  end

  describe ":spawn_next" do
    test "copies the latest card into the next occurrence", ctx do
      windows = [%{start_minute: 0, end_minute: 600}]

      task =
        task!(ctx, %{
          priority: 3,
          weekly_cap_override: 80,
          windows_override: windows
        })

      rule = rule!(task, ctx)
      first = Ash.get!(Task, task.id)
      finish!(first)

      rule = Ash.update!(rule, %{}, action: :spawn_next)

      assert [_first, next] = series(rule)
      assert next.title == "recurring"
      assert next.description == "do the thing"
      assert next.priority == 3
      assert next.weekly_cap_override == 80
      assert [%{start_minute: 0, end_minute: 600}] = next.windows_override
      assert next.project_id == ctx.project.id
      assert next.agent_id == ctx.agent.id
      assert next.creator_id == ctx.user.id
      assert next.stage == :todo
      assert next.state == :queued
      assert DateTime.diff(next.start_at, first.start_at) == 86_400
      assert DateTime.compare(next.start_at, rule.next_run_at) == :eq
    end

    test "cancelling the upcoming card skips its slot, not repeats it", ctx do
      task = task!(ctx)
      rule = rule!(task, ctx)
      first = Ash.get!(Task, task.id)
      finish!(first)

      Ash.update!(rule, %{}, action: :spawn_next)

      assert [_first, next] = series(rule)
      assert DateTime.diff(next.start_at, first.start_at) == 86_400
    end

    test "carries edits made to the latest card forward", ctx do
      task = task!(ctx)
      rule = rule!(task, ctx)

      task
      |> Ash.reload!()
      |> Ash.update!(%{title: "renamed", description: "new steps"})
      |> finish!()

      Ash.update!(rule, %{}, action: :spawn_next)

      assert [_first, next] = series(rule)
      assert next.title == "renamed"
      assert next.description == "new steps"
    end

    test "keeps the deadline at the same offset from the start", ctx do
      task = task!(ctx)
      rule = rule!(task, ctx)
      task = Ash.get!(Task, task.id)

      task
      |> Ash.update!(
        %{start_at: task.start_at, deadline_at: DateTime.add(task.start_at, 3600, :second)},
        action: :set_schedule
      )
      |> finish!()

      Ash.update!(rule, %{}, action: :spawn_next)

      assert [_first, next] = series(rule)
      assert DateTime.diff(next.deadline_at, next.start_at) == 3600
    end

    test "starts the next card in execution when the rule skips planning", ctx do
      task = task!(ctx, %{skip_planning: true})
      rule = rule!(task, ctx, %{skip_planning: true})
      finish!(Ash.get!(Task, task.id))

      Ash.update!(rule, %{}, action: :spawn_next)

      assert [_first, next] = series(rule)
      assert next.stage == :executing
      assert next.plan == "do the thing"
    end

    test "a long gap still gives a single next card", ctx do
      task = task!(ctx)
      rule = rule!(task, ctx)

      # As though the series had been idle for weeks: one card for the
      # next slot after now, never a backlog.
      task
      |> Ash.reload!()
      |> Ash.Seed.update!(%{start_at: ~U[2020-01-01 08:00:00Z]})
      |> finish!()

      Ash.update!(rule, %{}, action: :spawn_next)

      assert [_first, next] = series(rule)
      assert within_a_day?(next.start_at)
      refute rule.id in due_rule_ids()
    end

    test "disables the rule once the next run is past ends_at", ctx do
      task = task!(ctx)
      rule = rule!(task, ctx)
      task |> Ash.reload!() |> finish!()

      rule =
        rule
        |> Ash.Seed.update!(%{ends_at: DateTime.utc_now()})
        |> Ash.update!(%{}, action: :spawn_next)

      refute rule.enabled
      assert rule.next_run_at == nil
      assert [_only] = series(rule)
    end
  end

  describe "spawn_next trigger scope" do
    test "picks a rule whose cards are all finished", ctx do
      task = task!(ctx)
      rule = rule!(task, ctx)

      refute rule.id in due_rule_ids()

      task |> Ash.reload!() |> finish!()

      assert rule.id in due_rule_ids()
    end

    test "skips a disabled rule", ctx do
      task = task!(ctx)
      rule = rule!(task, ctx)
      task |> Ash.reload!() |> finish!()

      Ash.update!(rule, %{}, action: :disable)

      refute rule.id in due_rule_ids()
    end

    test "skips a rule in an archived project", ctx do
      task = task!(ctx)
      rule = rule!(task, ctx)
      task |> Ash.reload!() |> finish!()

      Ash.update!(ctx.project, %{}, action: :archive)

      refute rule.id in due_rule_ids()
    end
  end
end
