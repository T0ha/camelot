defmodule Camelot.Agents.UsagePolicyTest do
  use Camelot.DataCase, async: true

  alias Camelot.Agents.UsagePolicy

  defp upsert(user, agent, attrs) do
    UsagePolicy
    |> Ash.Changeset.for_create(
      :upsert,
      Map.merge(%{user_id: user.id, agent_id: agent.id}, attrs)
    )
    |> Ash.create()
  end

  test "upserts on user + agent instead of duplicating" do
    user = user!()
    agent = agent!("claude_code")

    {:ok, first} = upsert(user, agent, %{weekly_cap_percent: 80})

    {:ok, second} =
      upsert(user, agent, %{
        weekly_cap_percent: 60,
        windows: [%{start_minute: 540, end_minute: 1020}]
      })

    assert first.id == second.id
    assert second.weekly_cap_percent == 60
    assert [%{start_minute: 540, end_minute: 1020}] = second.windows

    assert [%UsagePolicy{}] =
             UsagePolicy
             |> Ash.Query.for_read(:for_user, %{user_id: user.id})
             |> Ash.read!()
  end

  test "a policy per agent" do
    user = user!()
    {:ok, _} = upsert(user, agent!("claude_code"), %{weekly_cap_percent: 80})
    {:ok, _} = upsert(user, agent!("codex"), %{weekly_cap_percent: 50})

    assert 2 ==
             UsagePolicy
             |> Ash.Query.for_read(:for_user, %{user_id: user.id})
             |> Ash.read!()
             |> length()
  end

  test "the cap must be 1..100 or nil" do
    user = user!()
    agent = agent!("claude_code")

    assert {:error, _} = upsert(user, agent, %{weekly_cap_percent: 0})
    assert {:error, _} = upsert(user, agent, %{weekly_cap_percent: 101})
    assert {:ok, %{weekly_cap_percent: nil}} = upsert(user, agent, %{weekly_cap_percent: nil})
  end

  test "windows must stay inside the week and not be empty" do
    user = user!()
    agent = agent!("claude_code")

    assert {:error, _} = upsert(user, agent, %{windows: [%{start_minute: 0, end_minute: 10_080}]})
    assert {:error, _} = upsert(user, agent, %{windows: [%{start_minute: 60, end_minute: 60}]})

    assert {:ok, _} =
             upsert(user, agent, %{windows: [%{start_minute: 10_000, end_minute: 60}]})
  end
end
