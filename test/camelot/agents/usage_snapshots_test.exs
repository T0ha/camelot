defmodule Camelot.Agents.UsageSnapshotsTest do
  use Camelot.DataCase, async: true

  alias Camelot.Accounts.Credential
  alias Camelot.Agents.Session
  alias Camelot.Agents.UsageSnapshot
  alias Camelot.Agents.UsageSnapshots

  @now ~U[2026-10-19 12:00:00.000000Z]

  defp weekly(percent, resets_at \\ DateTime.add(@now, 3 * 86_400, :second)) do
    %{window: :weekly, used_percent: percent, resets_at: resets_at}
  end

  # For tests that read against the real clock: a window anchored on
  # `@now` expires once the wall clock passes `@now + 3 days`.
  defp live_weekly(percent) do
    weekly(percent, DateTime.add(DateTime.utc_now(), 3 * 86_400, :second))
  end

  defp credential!(user, kind \\ :claude_api_key) do
    {:ok, credential} = Ash.create(Credential, %{user_id: user.id, kind: kind, value: "secret"})
    credential
  end

  describe "record/4" do
    test "attributes the snapshot to the user's credential of that kind" do
      user = user!()
      credential = credential!(user)

      assert {:ok, [snapshot]} =
               UsageSnapshots.record(user.id, :claude_api_key, [weekly(23.0)], :cli)

      assert snapshot.credential_id == credential.id
      assert snapshot.user_id == user.id
      assert snapshot.credential_kind == :claude_api_key
      assert snapshot.source == :cli
      assert snapshot.used_percent == 23.0
    end

    test "falls back to user + kind when the key comes from an env var" do
      user = user!()

      assert {:ok, [snapshot]} =
               UsageSnapshots.record(user.id, :claude_api_key, [weekly(10.0)], :cli)

      assert snapshot.credential_id == nil
      assert snapshot.user_id == user.id
    end

    test "writes one row per window" do
      user = user!()
      session = %{window: :session, used_percent: 40.0, resets_at: DateTime.add(@now, 3600, :second)}

      assert {:ok, rows} =
               UsageSnapshots.record(user.id, :claude_api_key, [weekly(23.0), session], :cli)

      assert rows |> Enum.map(& &1.window) |> Enum.sort() == [:session, :weekly]
    end

    test "nothing to record is a no-op" do
      assert {:ok, []} = UsageSnapshots.record(user!().id, :claude_api_key, [], :cli)
    end
  end

  describe "latest_weekly/3" do
    test "the most recent weekly row wins" do
      user = user!()
      {:ok, _} = UsageSnapshots.record(user.id, :claude_api_key, [weekly(10.0)], :cli)
      {:ok, _} = UsageSnapshots.record(user.id, :claude_api_key, [weekly(30.0)], :cli)

      assert %UsageSnapshot{used_percent: 30.0} =
               UsageSnapshots.latest_weekly(user.id, :claude_api_key, @now)
    end

    test "a snapshot whose window already reset is stale" do
      user = user!()

      {:ok, _} =
        UsageSnapshots.record(
          user.id,
          :claude_api_key,
          [weekly(90.0, DateTime.add(@now, -60, :second))],
          :cli
        )

      assert UsageSnapshots.latest_weekly(user.id, :claude_api_key, @now) == nil
    end

    test "snapshots on a credential are not mixed with env-var ones, nor across kinds" do
      user = user!()
      {:ok, _} = UsageSnapshots.record(user.id, :claude_api_key, [weekly(70.0)], :cli)
      {:ok, _} = UsageSnapshots.record(user.id, :openai_api_key, [weekly(5.0)], :manual)

      _credential = credential!(user)

      # The env-var row predates the credential the next run will use.
      assert UsageSnapshots.latest_weekly(user.id, :claude_api_key, @now) == nil
      assert %{used_percent: 5.0} = UsageSnapshots.latest_weekly(user.id, :openai_api_key, @now)
    end

    test "other users' snapshots are invisible" do
      {:ok, _} = UsageSnapshots.record(user!().id, :claude_api_key, [weekly(70.0)], :cli)

      assert UsageSnapshots.latest_weekly(user!().id, :claude_api_key, @now) == nil
    end
  end

  describe "effective_weekly/4" do
    test "a :cli snapshot is returned as is" do
      user = user!()
      {:ok, _} = UsageSnapshots.record(user.id, :claude_api_key, [weekly(40.0)], :cli)

      assert %{used_percent: 40.0, source: :cli} =
               UsageSnapshots.effective_weekly(user.id, :claude_api_key, @now, 30)
    end

    test "a manual reading adds Camelot's own run time since it was taken" do
      user = user!()
      agent = agent!("codex")
      observed_at = DateTime.add(DateTime.utc_now(), -3600, :second)

      {:ok, _} =
        UsageSnapshots.record(user.id, :openai_api_key, [live_weekly(5.0)], :manual, observed_at: observed_at)

      {:ok, session} = Ash.create(Session, %{agent_id: agent.id, user_id: user.id})
      {:ok, _} = Ash.update(session, %{duration_ms: 45 * 60_000}, action: :complete)

      # A session on a different credential kind does not count.
      {:ok, other} = Ash.create(Session, %{agent_id: agent!("claude_code").id, user_id: user.id})
      {:ok, _} = Ash.update(other, %{duration_ms: 600 * 60_000}, action: :complete)

      now = DateTime.utc_now()

      assert %{used_percent: 6.5, source: :estimated} =
               UsageSnapshots.effective_weekly(user.id, :openai_api_key, now, 30)
    end

    test "a manual reading with no runs since stays :manual" do
      user = user!()
      {:ok, _} = UsageSnapshots.record(user.id, :openai_api_key, [live_weekly(5.0)], :manual)

      assert %{used_percent: 5.0, source: :manual} =
               UsageSnapshots.effective_weekly(user.id, :openai_api_key, DateTime.utc_now(), 30)
    end

    test "nil without a snapshot" do
      assert UsageSnapshots.effective_weekly(user!().id, :claude_api_key, @now, 30) == nil
    end
  end

  describe "batch_latest/2" do
    test "returns the effective weekly snapshot per user + kind" do
      a = user!()
      b = user!()
      {:ok, _} = UsageSnapshots.record(a.id, :claude_api_key, [weekly(10.0)], :cli)
      {:ok, _} = UsageSnapshots.record(a.id, :claude_api_key, [weekly(20.0)], :cli)
      {:ok, _} = UsageSnapshots.record(b.id, :claude_api_key, [weekly(50.0)], :cli)

      result =
        UsageSnapshots.batch_latest(
          [{a.id, :claude_api_key}, {b.id, :claude_api_key}, {b.id, :openai_api_key}],
          @now
        )

      assert %{used_percent: 20.0} = result[{a.id, :claude_api_key}]
      assert %{used_percent: 50.0} = result[{b.id, :claude_api_key}]
      assert result[{b.id, :openai_api_key}] == nil
    end
  end
end
