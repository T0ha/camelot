defmodule Camelot.Accounts.UserCredentials do
  @moduledoc """
  Answers which credential kinds a user holds, and whether they cover
  what an agent CLI needs to authenticate.

  Separate from `Camelot.Accounts.Credential` because that module is
  Ash DSL only. It is the read side of the same constraint
  `CamelotWeb.Onboarding.claude_token?/1` documents: `Credential` runs
  with `authorizers: []`, so the `user_id` filter in `held_kinds/1`
  *is* the access control — never drop it. Only `:kind` is selected,
  so the encrypted `:value` is never decrypted to answer a question
  about mere presence.

  Both predicates degrade *open*: an agent declaring no kinds, and a
  form with no agent picked yet, are covered. The point is to name a
  missing key before a run starts, not to invent a requirement.
  """
  alias Camelot.Accounts.Credential
  alias Camelot.Accounts.User
  alias Camelot.Agents.Agent

  require Ash.Query

  @doc "The credential kinds `user` currently holds."
  @spec held_kinds(User.t()) :: MapSet.t(atom())
  def held_kinds(%User{id: user_id}) do
    Credential
    |> Ash.Query.filter(user_id == ^user_id)
    |> Ash.Query.select([:kind])
    |> Ash.read!()
    |> MapSet.new(& &1.kind)
  end

  @doc """
  The kinds `agent` requires that `held` doesn't cover.

  A `nil` agent — nothing picked in the form yet — is missing nothing:
  that is the form's own `required` error to report, not a credential
  problem.
  """
  @spec missing_kinds(MapSet.t(atom()), Agent.t() | nil) :: [atom()]
  def missing_kinds(_held, nil), do: []

  def missing_kinds(held, %Agent{required_credential_kinds: kinds}) do
    Enum.reject(kinds, &MapSet.member?(held, &1))
  end

  @doc """
  Whether `held` satisfies every kind `agent` requires.

  An agent that declares none is always covered — `required_credential_kinds`
  describes what the CLI needs mounted, and a CLI that needs nothing
  mounted is one the user can always pick.
  """
  @spec covered?(MapSet.t(atom()), Agent.t() | nil) :: boolean()
  def covered?(held, agent), do: missing_kinds(held, agent) == []
end
