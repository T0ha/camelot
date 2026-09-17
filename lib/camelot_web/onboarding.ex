defmodule CamelotWeb.Onboarding do
  @moduledoc """
  Works out what a newly signed-up user still has to do
  before they can run their first task, and records when
  they've dismissed or finished the guide.

  Every step is *detected* rather than remembered, so the
  guide tells the truth for users who arrive pre-equipped —
  a "Log in with GitHub" user lands with their App
  installation already linked (see
  `CamelotWeb.GithubLoginFlow`), and existing accounts
  never see the guide at all.

  This lives in the web layer because it reuses
  `CamelotWeb.Scope`'s membership filters; putting it under
  `lib/camelot/` would invert the domain → web dependency.
  """
  alias Camelot.Accounts.Credential
  alias Camelot.Accounts.User
  alias Camelot.Board.Task
  alias Camelot.Github.AppConfig
  alias Camelot.Projects.Project
  alias CamelotWeb.Onboarding.Status
  alias CamelotWeb.Scope

  require Ash.Query

  @doc """
  Current setup status for `user`, one query per applicable
  step.
  """
  @spec status(User.t()) :: Status.t()
  def status(%User{} = user) do
    applicable_steps()
    |> Enum.map(&{&1, done?(&1, user)})
    |> Status.new()
  end

  @doc """
  Re-checks `status` for `user`, querying only the steps that
  are still outstanding.

  A finished step can't come undone, and which steps apply is
  fixed for the session, so a navigation costs one query per
  *pending* step rather than one per step.
  """
  @spec refresh(Status.t(), User.t()) :: Status.t()
  def refresh(%Status{steps: steps}, %User{} = user) do
    steps
    |> Enum.map(&recheck(&1, user))
    |> Status.new()
  end

  @doc "Records that the user closed the welcome modal."
  @spec dismiss!(User.t()) :: User.t()
  def dismiss!(%User{} = user) do
    Ash.update!(user, %{}, action: :dismiss_onboarding, actor: user)
  end

  @doc "Records that the user finished every applicable step."
  @spec mark_complete!(User.t()) :: User.t()
  def mark_complete!(%User{} = user) do
    Ash.update!(user, %{}, action: :complete_onboarding, actor: user)
  end

  defp recheck({_step, true} = done, _user), do: done
  defp recheck({step, false}, user), do: {step, done?(step, user)}

  defp done?(:github, user), do: github_connected?(user)
  defp done?(:claude_token, user), do: claude_token?(user)
  defp done?(:project, user), do: project?(user)
  defp done?(:task, user), do: task?(user)

  # The GitHub App is opt-in per deployment. Where it isn't
  # configured there is nothing to connect, so the step
  # drops out of the guide entirely.
  defp applicable_steps do
    if AppConfig.configured?() do
      [:github, :claude_token, :project, :task]
    else
      [:claude_token, :project, :task]
    end
  end

  defp github_connected?(%User{} = user) do
    case Ash.load(user, :github_installations, actor: user) do
      {:ok, %User{github_installations: installations}} -> Enum.any?(installations, &live?/1)
      {:error, _reason} -> false
    end
  end

  # A suspended installation can't mint tokens, so it
  # doesn't count as connected.
  defp live?(installation), do: is_nil(installation.suspended_at)

  # `Credential` runs with `authorizers: []`, so the
  # user_id filter here *is* the access control — never
  # drop it, and never load the encrypted `:value`.
  defp claude_token?(%User{id: user_id}) do
    Credential
    |> Ash.Query.filter(user_id == ^user_id and kind == :claude_api_key)
    |> Ash.exists?()
  end

  defp project?(%User{} = user) do
    Project
    |> Scope.scope_projects(user)
    |> Ash.exists?()
  end

  defp task?(%User{} = user) do
    Task
    |> Scope.scope_tasks(user)
    |> Ash.exists?()
  end
end
