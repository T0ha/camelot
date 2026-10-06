defmodule Camelot.Accounts.UserCredentialsTest do
  use Camelot.DataCase, async: true

  alias Camelot.Accounts.Credential
  alias Camelot.Accounts.UserCredentials
  alias Camelot.Agents.Agent

  setup do
    %{user: user!(), other: user!()}
  end

  describe "held_kinds/1" do
    test "is empty for a user who has added nothing", ctx do
      assert UserCredentials.held_kinds(ctx.user) == MapSet.new()
    end

    test "reports the kinds the user holds", ctx do
      credential!(ctx.user, :claude_api_key)
      credential!(ctx.user, :ssh_private_key)

      assert UserCredentials.held_kinds(ctx.user) ==
               MapSet.new([:claude_api_key, :ssh_private_key])
    end

    # `Credential` runs with `authorizers: []`, so the user_id filter
    # is the access control rather than a convenience.
    test "never reports another user's kinds", ctx do
      credential!(ctx.other, :claude_api_key)

      assert UserCredentials.held_kinds(ctx.user) == MapSet.new()
      assert UserCredentials.held_kinds(ctx.other) == MapSet.new([:claude_api_key])
    end

    test "collapses two credentials of the same kind", ctx do
      credential!(ctx.user, :generic, "one")
      credential!(ctx.user, :generic, "two")

      assert UserCredentials.held_kinds(ctx.user) == MapSet.new([:generic])
    end
  end

  describe "missing_kinds/2" do
    test "lists only the kinds the user doesn't hold", ctx do
      credential!(ctx.user, :claude_api_key)
      held = UserCredentials.held_kinds(ctx.user)

      assert UserCredentials.missing_kinds(
               held,
               requiring([:claude_api_key, :openai_api_key])
             ) == [:openai_api_key]
    end

    # Nothing picked yet is the form's own `required` error, not a
    # credential problem — so the agent select must not also shout.
    test "a nil agent is missing nothing", ctx do
      held = UserCredentials.held_kinds(ctx.user)

      assert UserCredentials.missing_kinds(held, nil) == []
    end
  end

  describe "covered?/2" do
    test "an agent that declares no kinds is always pickable", ctx do
      held = UserCredentials.held_kinds(ctx.user)

      assert UserCredentials.covered?(held, requiring([]))
    end

    test "a nil agent is covered", ctx do
      held = UserCredentials.held_kinds(ctx.user)

      assert UserCredentials.covered?(held, nil)
    end

    test "is false while any required kind is absent", ctx do
      credential!(ctx.user, :claude_api_key)
      held = UserCredentials.held_kinds(ctx.user)

      assert UserCredentials.covered?(held, requiring([:claude_api_key]))
      refute UserCredentials.covered?(held, requiring([:openai_api_key]))
    end

    test "the seeded agents split on which key the user added", ctx do
      credential!(ctx.user, :claude_api_key)
      held = UserCredentials.held_kinds(ctx.user)

      assert UserCredentials.covered?(held, agent!("claude_code"))
      refute UserCredentials.covered?(held, agent!("codex"))
    end
  end

  defp requiring(kinds), do: struct(Agent, required_credential_kinds: kinds)

  defp credential!(user, kind, name \\ nil) do
    Ash.create!(Credential, %{
      user_id: user.id,
      kind: kind,
      name: name,
      value: "secret-#{System.unique_integer([:positive])}"
    })
  end
end
