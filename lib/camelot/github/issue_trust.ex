defmodule Camelot.Github.IssueTrust do
  @moduledoc """
  The single answer to "may this GitHub account make Camelot act on
  project P?" for the GitHub issue workflow.

  A GitHub account is **trusted** when a Camelot user signed in with it
  (`Camelot.Accounts.User.github_user_id`) holds any membership on the
  project, and an **owner** when that membership's role is `:owner`.
  GitHub's own `author_association` is deliberately not consulted: a
  repository collaborator is not necessarily someone allowed to spend
  this project's agent credits, and the reverse.

  Everything else — strangers' labels, comments and reactions — is
  ignored, except that a project owner can vouch for one specific
  stranger comment (or a stranger-authored issue) with a 👍 reaction;
  see `owner_approved?/3`. Lookups run with `authorize?: false`: they
  run unattended from Oban jobs with no web actor, like
  `Camelot.Projects.Membership.owner?/2`.
  """

  alias Camelot.Projects.Membership

  require Ash.Query

  @typedoc "GitHub's numeric user id, as the API sends it or stringified."
  @type github_user_id :: integer() | String.t() | nil

  @thumbs_up "+1"

  @doc "Whether `github_user_id` belongs to a member (any role) of the project."
  @spec trusted?(github_user_id(), Ash.UUID.t()) :: boolean()
  def trusted?(nil, _project_id), do: false

  def trusted?(github_user_id, project_id) do
    gh_id = to_string(github_user_id)

    Membership
    |> Ash.Query.filter(project_id == ^project_id and user.github_user_id == ^gh_id)
    |> Ash.exists?(authorize?: false)
  end

  @doc "Whether `github_user_id` belongs to an owner of the project."
  @spec owner?(github_user_id(), Ash.UUID.t()) :: boolean()
  def owner?(nil, _project_id), do: false

  def owner?(github_user_id, project_id) do
    gh_id = to_string(github_user_id)

    Membership
    |> Ash.Query.filter(project_id == ^project_id and role == :owner and user.github_user_id == ^gh_id)
    |> Ash.exists?(authorize?: false)
  end

  @doc """
  The GitHub user id behind a comment, reaction (`"user"`) or issue
  event (`"actor"`), stringified; `nil` when there is none (a deleted
  "ghost" account).
  """
  @spec actor_id(map()) :: String.t() | nil
  def actor_id(%{"user" => %{"id" => id}}), do: to_string(id)
  def actor_id(%{"actor" => %{"id" => id}}), do: to_string(id)
  def actor_id(_entry), do: nil

  @doc """
  The owner 👍 that vouches for `subject` (a stranger's comment or
  issue), or `nil`.

  A reaction only counts when it is newer than the subject's
  `updated_at`: an edit made after the owner approved voids the
  approval, so a stranger cannot get a harmless comment approved and
  then swap its text.
  """
  @spec owner_approval(map(), [map()], Ash.UUID.t()) :: map() | nil
  def owner_approval(subject, reactions, project_id) do
    Enum.find(reactions, fn reaction ->
      thumbs_up?(reaction) and
        not edited_after?(subject, reaction) and
        owner?(actor_id(reaction), project_id)
    end)
  end

  @doc "Whether a project owner vouched for `subject` — see `owner_approval/3`."
  @spec owner_approved?(map(), [map()], Ash.UUID.t()) :: boolean()
  def owner_approved?(subject, reactions, project_id) do
    not is_nil(owner_approval(subject, reactions, project_id))
  end

  @doc "Whether a reaction is a 👍."
  @spec thumbs_up?(map()) :: boolean()
  def thumbs_up?(%{"content" => @thumbs_up}), do: true
  def thumbs_up?(_reaction), do: false

  # GitHub timestamps are all ISO 8601 UTC with a `Z`, so they compare
  # correctly as strings.
  defp edited_after?(subject, reaction) do
    later?(subject["updated_at"], reaction["created_at"])
  end

  defp later?(nil, _reacted_at), do: false
  defp later?(_updated_at, nil), do: false
  defp later?(updated_at, reacted_at), do: updated_at > reacted_at
end
