defmodule CamelotWeb.UsageSchedulingLiveTest do
  use CamelotWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Camelot.Accounts.Credential
  alias Camelot.Accounts.User
  alias Camelot.Agents.UsagePolicy
  alias Camelot.Agents.UsageSnapshot
  alias Camelot.Agents.UsageSnapshots
  alias Camelot.Board.Task
  alias Camelot.Projects.Project

  require Ash.Query

  setup :register_and_log_in_user

  setup %{user: user} do
    Ash.create!(Credential, %{kind: :claude_api_key, value: "sk-ant", user_id: user.id})

    user = Ash.update!(user, %{time_zone: "Europe/Berlin"}, action: :set_time_zone, actor: user)

    project =
      Ash.create!(
        Project,
        %{name: "sched-#{System.unique_integer([:positive])}", path: "/tmp/sched"},
        actor: user
      )

    %{user: user, project: project, agent: agent!("claude_code")}
  end

  defp policy_for(user, agent) do
    UsagePolicy
    |> Ash.Query.filter(user_id == ^user.id and agent_id == ^agent.id)
    |> Ash.read_one!()
  end

  defp task!(ctx, attrs \\ %{}) do
    Ash.create!(
      Task,
      Map.merge(
        %{
          title: "card-#{System.unique_integer([:positive])}",
          project_id: ctx.project.id,
          creator_id: ctx.user.id,
          agent_id: ctx.agent.id
        },
        attrs
      )
    )
  end

  defp weekly_usage!(user, percent, source \\ :manual) do
    {:ok, _} =
      UsageSnapshots.record(
        user.id,
        :claude_api_key,
        [%{window: :weekly, used_percent: percent, resets_at: ~U[2030-01-07 08:00:00Z]}],
        source
      )
  end

  describe "profile usage limits" do
    test "renders a section per agent", %{conn: conn, agent: agent} do
      {:ok, view, html} = live(conn, ~p"/profile")

      assert html =~ "Usage limits"
      assert has_element?(view, "#usage-policy-#{agent.slug}")
      assert has_element?(view, "#time-zone-form")
    end

    test "saving the time zone persists it", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/profile")

      view
      |> form("#time-zone-form", %{"tz" => %{"time_zone" => "America/New_York"}})
      |> render_submit()

      assert Ash.get!(User, user.id, authorize?: false).time_zone == "America/New_York"
    end

    test "saves the cap and converts local window rows to UTC", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/profile")

      view
      |> form("#usage-policy-#{ctx.agent.slug}", %{
        "policy" => %{
          "weekly_cap_percent" => "80",
          "windows" => %{
            "0" => %{"d1" => "true", "d2" => "false", "from" => "09:00", "to" => "17:00"}
          }
        }
      })
      |> render_submit()

      policy = policy_for(ctx.user, ctx.agent)
      assert policy.weekly_cap_percent == 80

      # Berlin is UTC+1 or +2; either way 09:00 local is before 09:00 UTC.
      assert [%{start_minute: start, end_minute: finish}] = policy.windows
      assert start in [420, 480]
      assert finish - start == 480
    end

    test "a blank cap clears it", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/profile")

      view
      |> form("#usage-policy-#{ctx.agent.slug}", %{"policy" => %{"weekly_cap_percent" => ""}})
      |> render_submit()

      assert %{weekly_cap_percent: nil, windows: []} = policy_for(ctx.user, ctx.agent)
    end

    test "a manual current-% reading writes a :manual snapshot", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/profile")

      view
      |> form("#usage-policy-#{ctx.agent.slug}", %{"policy" => %{"current_percent" => "42"}})
      |> render_submit()

      assert [%UsageSnapshot{used_percent: 42.0, source: :manual, window: :weekly}] =
               UsageSnapshot
               |> Ash.Query.filter(user_id == ^ctx.user.id)
               |> Ash.read!()
    end

    test "shows the current snapshot, its source and its reset in local time", ctx do
      weekly_usage!(ctx.user, 23.0, :cli)

      {:ok, view, _html} = live(ctx.conn, ~p"/profile")
      html = view |> element("#usage-policy-#{ctx.agent.slug}-snapshot") |> render()

      assert html =~ "23%"
      assert html =~ "cli"
      # 08:00 UTC on 2030-01-07 is 09:00 CET.
      assert html =~ "09:00 CET"
    end
  end

  describe "task schedule" do
    test "saving the schedule converts local times and pins the card", ctx do
      task = task!(ctx)
      {:ok, view, _html} = live(ctx.conn, ~p"/tasks/#{task.id}")

      view
      |> form("#task-schedule-form", %{
        "schedule" => %{
          "start_at" => "2030-01-07T10:00",
          "deadline_at" => "",
          "weekly_cap_override" => "90"
        }
      })
      |> render_submit()

      task = Ash.get!(Task, task.id)
      assert DateTime.compare(task.start_at, ~U[2030-01-07 09:00:00Z]) == :eq
      assert task.deadline_at == nil
      assert task.weekly_cap_override == 90
      assert task.ignore_limits == true
    end

    test "an unchecked 'run even if over limits' is respected", ctx do
      task = task!(ctx)
      {:ok, view, _html} = live(ctx.conn, ~p"/tasks/#{task.id}")

      view
      |> form("#task-schedule-form", %{
        "schedule" => %{"start_at" => "2030-01-07T10:00", "ignore_limits" => "false"}
      })
      |> render_submit()

      assert Ash.get!(Task, task.id).ignore_limits == false
    end

    test "warns when the snapshot is already over the effective cap", ctx do
      Ash.create!(UsagePolicy, %{user_id: ctx.user.id, agent_id: ctx.agent.id, weekly_cap_percent: 50},
        action: :upsert
      )

      weekly_usage!(ctx.user, 60.0)
      task = task!(ctx)

      {:ok, view, _html} = live(ctx.conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#schedule-reserve-warning")
    end

    test "no warning while under the cap", ctx do
      weekly_usage!(ctx.user, 10.0)
      task = task!(ctx)

      {:ok, view, _html} = live(ctx.conn, ~p"/tasks/#{task.id}")

      refute has_element?(view, "#schedule-reserve-warning")
    end
  end

  describe "board" do
    test "a card waiting on the cap shows a badge", ctx do
      Ash.create!(UsagePolicy, %{user_id: ctx.user.id, agent_id: ctx.agent.id, weekly_cap_percent: 5},
        action: :upsert
      )

      weekly_usage!(ctx.user, 60.0)
      task = task!(ctx)

      {:ok, view, _html} = live(ctx.conn, ~p"/")

      assert view |> element("#task-#{task.id}-schedule") |> render() =~ "Weekly cap"
    end

    test "a card due soon shows it was promoted", ctx do
      task = task!(ctx, %{deadline_at: DateTime.add(DateTime.utc_now(), 3 * 3600, :second)})

      {:ok, view, _html} = live(ctx.conn, ~p"/")

      refute has_element?(view, "#task-#{task.id}-schedule")

      task = task!(ctx, %{deadline_at: DateTime.add(DateTime.utc_now(), 10 * 60, :second)})
      {:ok, view, _html} = live(ctx.conn, ~p"/")

      assert view |> element("#task-#{task.id}-schedule") |> render() =~ "deadline"
    end

    test "the create form accepts a local start time", ctx do
      title = "with-start-#{System.unique_integer([:positive])}"
      {:ok, view, _html} = live(ctx.conn, ~p"/")

      render_click(view, "open_new_task")

      view
      |> form("#new-task-form", %{
        "task" => %{
          "title" => title,
          "project_id" => ctx.project.id,
          "agent_id" => ctx.agent.id,
          "start_at" => "2030-01-07T10:00",
          "deadline_at" => ""
        }
      })
      |> render_submit()

      task = Task |> Ash.Query.filter(title == ^title) |> Ash.read_one!()
      assert DateTime.compare(task.start_at, ~U[2030-01-07 09:00:00Z]) == :eq
      assert task.deadline_at == nil
    end
  end
end
