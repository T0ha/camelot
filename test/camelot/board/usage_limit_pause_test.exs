defmodule Camelot.Board.UsageLimitPauseTest do
  use Camelot.DataCase, async: false

  alias Camelot.Accounts.Credential
  alias Camelot.Board.Task
  alias Camelot.Board.UsageLimitPause
  alias Camelot.Board.Workers.SendUsageLimitEmail
  alias Camelot.Projects.Project

  setup do
    {:ok, project} =
      Ash.create(Project, %{
        name: "ulp-proj-#{System.unique_integer()}",
        path: "/tmp/ulp-proj-#{System.unique_integer()}"
      })

    user = user!()

    %{project: project, user: user}
  end

  defp create_task(ctx, attrs \\ %{}) do
    defaults = %{
      title: "task-#{System.unique_integer([:positive])}",
      project_id: ctx.project.id,
      creator_id: ctx.user.id,
      agent_id: agent!("claude_code").id
    }

    {:ok, task} = Ash.create(Task, Map.merge(defaults, attrs))
    task
  end

  defp credential!(user, kind, attrs \\ %{}) do
    defaults = %{user_id: user.id, kind: kind, value: "secret-#{System.unique_integer()}"}
    {:ok, credential} = Ash.create(Credential, Map.merge(defaults, attrs))
    credential
  end

  defp info(reset_at, window \\ "5h") do
    %{reset_at: reset_at, window: window}
  end

  describe "pause/3" do
    test "marks the credential limited and pauses every queued sibling", ctx do
      credential!(ctx.user, :claude_api_key)
      task = create_task(ctx)
      sibling = create_task(ctx)
      other_user_task = create_task(%{project: ctx.project, user: user!()})

      reset_at = DateTime.add(DateTime.utc_now(), 3600, :second)

      assert :ok = UsageLimitPause.pause(task.id, :claude_api_key, info(reset_at))

      assert Ash.get!(Task, task.id).state == :paused
      assert Ash.get!(Task, sibling.id).state == :paused
      assert Ash.get!(Task, other_user_task.id).state == :queued

      credential = Ash.get!(Credential, Credential.for_user_and_kind(ctx.user.id, :claude_api_key).id)
      assert credential.usage_limited_until
      assert credential.usage_limit_window == "5h"
    end

    test "leaves a sibling needing a different credential kind alone", ctx do
      credential!(ctx.user, :claude_api_key)
      task = create_task(ctx)
      other_kind_sibling = create_task(ctx, %{agent_id: agent!("codex").id})

      assert :ok = UsageLimitPause.pause(task.id, :claude_api_key, info(DateTime.utc_now()))

      assert Ash.get!(Task, other_kind_sibling.id).state == :queued
    end

    test "with no Credential row, pauses only this task (env-var token)", ctx do
      task = create_task(ctx)
      sibling = create_task(ctx)

      assert :ok = UsageLimitPause.pause(task.id, :claude_api_key, info(DateTime.utc_now()))

      assert Ash.get!(Task, task.id).state == :paused
      assert Ash.get!(Task, sibling.id).state == :queued
    end

    test "enqueues exactly one pause email for the owner", ctx do
      credential!(ctx.user, :claude_api_key)
      task = create_task(ctx)
      create_task(ctx)

      assert :ok = UsageLimitPause.pause(task.id, :claude_api_key, info(DateTime.utc_now()))

      assert_enqueued(
        worker: SendUsageLimitEmail,
        args: %{"user_id" => ctx.user.id, "kind" => "paused"}
      )
    end
  end

  describe "resume_due/1" do
    test "clears an expired credential limit and resumes its paused tasks", ctx do
      credential = credential!(ctx.user, :claude_api_key)
      task = create_task(ctx)

      past = DateTime.add(DateTime.utc_now(), -60, :second)
      future = DateTime.add(DateTime.utc_now(), 3600, :second)

      {:ok, _} =
        Ash.update(
          credential,
          %{usage_limited_until: past, usage_limit_window: "5h"},
          action: :mark_usage_limited
        )

      {:ok, _} =
        Ash.update(task, %{paused_until: past, pause_reason: "usage limit"}, action: :pause_for_usage_limit)

      still_paused = create_task(ctx)

      {:ok, _} =
        Ash.update(
          still_paused,
          %{paused_until: future, pause_reason: "usage limit"},
          action: :pause_for_usage_limit
        )

      assert :ok = UsageLimitPause.resume_due(DateTime.utc_now())

      assert Ash.get!(Task, task.id).state == :queued
      assert Ash.get!(Credential, credential.id).usage_limited_until == nil
      assert Ash.get!(Task, still_paused.id).state == :paused
    end

    test "a task whose paused_until is due stays paused while its credential is still limited", ctx do
      credential = credential!(ctx.user, :claude_api_key)
      task = create_task(ctx)

      past = DateTime.add(DateTime.utc_now(), -60, :second)
      still_future = DateTime.add(DateTime.utc_now(), 3600, :second)

      {:ok, _} =
        Ash.update(
          credential,
          %{usage_limited_until: still_future, usage_limit_window: "5h"},
          action: :mark_usage_limited
        )

      {:ok, _} =
        Ash.update(task, %{paused_until: past, pause_reason: "usage limit"}, action: :pause_for_usage_limit)

      assert :ok = UsageLimitPause.resume_due(DateTime.utc_now())

      assert Ash.get!(Task, task.id).state == :paused
      assert Ash.get!(Credential, credential.id).usage_limited_until
    end

    test "enqueues one resume email per owner", ctx do
      task = create_task(ctx)
      past = DateTime.add(DateTime.utc_now(), -60, :second)

      {:ok, _} =
        Ash.update(task, %{paused_until: past, pause_reason: "usage limit"}, action: :pause_for_usage_limit)

      assert :ok = UsageLimitPause.resume_due(DateTime.utc_now())

      assert_enqueued(
        worker: SendUsageLimitEmail,
        args: %{"user_id" => ctx.user.id, "kind" => "resumed"}
      )
    end
  end

  describe "resume_now/1" do
    test "clears the credential and resumes every paused sibling immediately", ctx do
      credential = credential!(ctx.user, :claude_api_key)
      future = DateTime.add(DateTime.utc_now(), 3600, :second)

      {:ok, _} =
        Ash.update(
          credential,
          %{usage_limited_until: future, usage_limit_window: "5h"},
          action: :mark_usage_limited
        )

      task = create_task(ctx)
      sibling = create_task(ctx)

      {:ok, task} =
        Ash.update(task, %{paused_until: future, pause_reason: "usage limit"}, action: :pause_for_usage_limit)

      {:ok, _} =
        Ash.update(sibling, %{paused_until: future, pause_reason: "usage limit"}, action: :pause_for_usage_limit)

      assert :ok = UsageLimitPause.resume_now(task)

      assert Ash.get!(Task, task.id).state == :queued
      assert Ash.get!(Task, sibling.id).state == :queued
      assert Ash.get!(Credential, credential.id).usage_limited_until == nil
    end

    test "with no Credential row, resumes just this task", ctx do
      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      task = create_task(ctx)
      sibling = create_task(ctx)

      {:ok, task} =
        Ash.update(task, %{paused_until: future, pause_reason: "usage limit"}, action: :pause_for_usage_limit)

      {:ok, _} =
        Ash.update(sibling, %{paused_until: future, pause_reason: "usage limit"}, action: :pause_for_usage_limit)

      assert :ok = UsageLimitPause.resume_now(task)

      assert Ash.get!(Task, task.id).state == :queued
      assert Ash.get!(Task, sibling.id).state == :paused
    end
  end
end
