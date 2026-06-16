defmodule CamelotWeb.Scope do
  @moduledoc """
  Visibility filters applied at the LiveView load layer.

  Resources stay open at the Ash policy layer (so managed-relationship
  lookups, seeds, and mix tasks keep working). The UI scopes reads to
  the current user's project memberships unless the actor is an admin
  who has explicitly opted into the "Showing: All" toggle.
  """
  alias Camelot.Accounts.User

  require Ash.Query

  @doc """
  Returns `true` when the actor is allowed to bypass the scoping filter
  in the current view — admins with the "see all" toggle on.
  """
  @spec see_all?(User.t() | nil, boolean()) :: boolean()
  def see_all?(%User{role: :admin}, true), do: true
  def see_all?(_user, _toggle), do: false

  @typedoc """
  Either an Ash resource module or an `Ash.Query.t()`. Ash auto-wraps a
  bare resource module into a query when passed to `Ash.Query.filter/2`.
  """
  @type queryable :: Ash.Resource.t() | Ash.Query.t()

  @doc "Filter a Project query to projects the user is a member of."
  @spec scope_projects(queryable(), User.t()) :: Ash.Query.t()
  def scope_projects(query, %User{id: user_id}) do
    Ash.Query.filter(query, exists(memberships, user_id == ^user_id))
  end

  @doc "Filter a Task query to tasks whose project the user is a member of."
  @spec scope_tasks(queryable(), User.t()) :: Ash.Query.t()
  def scope_tasks(query, %User{id: user_id}) do
    Ash.Query.filter(query, exists(project.memberships, user_id == ^user_id))
  end

  @doc """
  Filter an Agent query to agents the user owns, or agents in projects
  the user is a member of.
  """
  @spec scope_agents(queryable(), User.t()) :: Ash.Query.t()
  def scope_agents(query, %User{id: user_id}) do
    Ash.Query.filter(
      query,
      user_id == ^user_id or exists(project.memberships, user_id == ^user_id)
    )
  end

  @doc """
  Filter a PromptTemplate query to system-global prompts (no project,
  no user), the user's own user-global prompts, or prompts in projects
  the user is a member of.
  """
  @spec scope_prompts(queryable(), User.t()) :: Ash.Query.t()
  def scope_prompts(query, %User{id: user_id}) do
    Ash.Query.filter(
      query,
      (is_nil(project_id) and is_nil(user_id)) or
        user_id == ^user_id or
        exists(project.memberships, user_id == ^user_id)
    )
  end

  @doc """
  Convenience: apply `scope_fun` to the query only when the actor doesn't
  see all. Lets callers write `Scope.maybe_scope(query, user, see_all, &Scope.scope_projects/2)`.
  """
  @spec maybe_scope(queryable(), User.t() | nil, boolean(), (queryable(), User.t() -> Ash.Query.t())) ::
          queryable()
  def maybe_scope(query, user, see_all, scope_fun) do
    if see_all?(user, see_all), do: query, else: scope_fun.(query, user)
  end
end
