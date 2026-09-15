defmodule Camelot.Accounts.User.Changes.ApplyGithubUserInfo do
  @moduledoc """
  Turns the `user_info` map assent hands back from GitHub
  into attributes on the `:register_with_github` changeset,
  and stashes the short-lived user access token on the
  resulting record's metadata.

  Security-critical: the change **refuses** any payload
  whose primary email GitHub has not verified.
  `Assent.Strategy.Github.get_primary_email/1` reports the
  first `"primary" => true` address regardless of its
  `verified` flag, and AshAuthentication never inspects
  `email_verified`. Without the check below, anybody could
  add an unverified `someone@yourcompany.com` to their
  GitHub account and take over that Camelot user via the
  `:unique_email` upsert.

  The email is cast but never downcased — the column is
  `citext`, and folding case here would only make the value
  differ from what existing rows store.
  """
  use Ash.Resource.Change

  alias Ash.Changeset
  alias Ash.Resource.Change

  @impl Change
  @spec change(Changeset.t(), keyword(), Change.context()) ::
          Changeset.t()
  def change(changeset, _opts, _context) do
    changeset
    |> apply_user_info(Changeset.get_argument(changeset, :user_info))
    |> stash_access_token(Changeset.get_argument(changeset, :oauth_tokens))
  end

  defp apply_user_info(changeset, %{"email" => email, "email_verified" => true, "sub" => sub})
       when is_binary(email) and not is_nil(sub) do
    changeset
    |> Changeset.change_attribute(:email, String.trim(email))
    |> Changeset.change_attribute(:github_user_id, to_string(sub))
  end

  defp apply_user_info(changeset, _user_info) do
    Changeset.add_error(changeset,
      field: :email,
      message:
        "GitHub did not return a verified primary email address. " <>
          "Verify your email on GitHub and grant the app " <>
          "read access to your email addresses."
    )
  end

  defp stash_access_token(changeset, %{"access_token" => token}) when is_binary(token) do
    Changeset.after_action(changeset, fn _changeset, user ->
      {:ok, Ash.Resource.put_metadata(user, :github_access_token, token)}
    end)
  end

  defp stash_access_token(changeset, _tokens), do: changeset
end
