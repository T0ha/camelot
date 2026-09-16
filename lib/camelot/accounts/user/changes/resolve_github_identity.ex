defmodule Camelot.Accounts.User.Changes.ResolveGithubIdentity do
  @moduledoc """
  Decides *which* Camelot user a GitHub sign-in belongs to,
  before the `:unique_email` upsert runs.

  GitHub's numeric user id is the stable anchor; email is
  only a fallback for a magic-link user signing in with
  GitHub for the first time.

  | Match | Outcome |
  | --- | --- |
  | Known `github_user_id`, same email | plain sign-in |
  | Known `github_user_id`, new email | sign in as the same user, email left alone, new address carried out as `:pending_github_email` metadata |
  | Unknown id, known email | sign in and backfill the id |
  | Neither | register (subject to the invite-only gate) |

  When the GitHub email changed, the `:email` attribute is
  rewritten *back* to the address already on the row so the
  upsert conflicts onto that same user instead of inserting
  a second one. Nothing is changed behind the user's back —
  adopting the new address needs an explicit confirmation,
  handled by `CamelotWeb.GithubEmailController`.
  """
  use Ash.Resource.Change

  alias Ash.Changeset
  alias Ash.Resource.Change
  alias Camelot.Accounts.User
  alias Camelot.Accounts.UserLookup

  @impl Change
  @spec change(Changeset.t(), keyword(), Change.context()) ::
          Changeset.t()
  def change(changeset, _opts, _context) do
    changeset
    |> Changeset.before_action(&resolve/1)
    |> Changeset.after_action(&put_pending_email/2)
  end

  defp resolve(changeset) do
    github_user_id = Changeset.get_attribute(changeset, :github_user_id)
    email = Changeset.get_attribute(changeset, :email)

    case UserLookup.fetch_by_github_user_id(github_user_id) do
      {:ok, %User{} = user} -> matched_by_github_id(changeset, user, email)
      :not_found -> matched_by_email(changeset, email)
    end
  end

  defp matched_by_github_id(changeset, user, email) do
    changeset
    |> Changeset.set_context(%{github_existing_user: user})
    |> keep_stored_email(user, email)
  end

  defp keep_stored_email(changeset, user, email) do
    if same_email?(user.email, email) do
      changeset
    else
      # force_: we're inside a before_action hook, past
      # validation. The replacement is an address already
      # persisted on that very row, so there is nothing left
      # to validate.
      changeset
      |> Changeset.force_change_attribute(:email, user.email)
      |> Changeset.set_context(%{github_pending_email: to_string(email)})
    end
  end

  defp matched_by_email(changeset, email) do
    case UserLookup.fetch_by_email(email) do
      {:ok, %User{} = user} ->
        Changeset.set_context(changeset, %{github_existing_user: user})

      :not_found ->
        changeset
    end
  end

  defp put_pending_email(changeset, user) do
    case changeset.context[:github_pending_email] do
      nil -> {:ok, user}
      email -> {:ok, Ash.Resource.put_metadata(user, :pending_github_email, email)}
    end
  end

  defp same_email?(left, right), do: downcase(left) == downcase(right)

  defp downcase(value), do: value |> to_string() |> String.downcase()
end
