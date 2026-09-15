defmodule Camelot.Accounts.User.RegisterWithGithubTest do
  @moduledoc """
  Drives the `:register_with_github` upsert directly — the
  action is where all the subtle identity behaviour lives,
  and it needs no GitHub credentials and makes no HTTP
  calls.
  """
  use Camelot.DataCase, async: false

  alias AshAuthentication.Errors.CannotConfirmUnconfirmedUser
  alias Camelot.Accounts.Credential
  alias Camelot.Accounts.User

  require Ash.Query

  @access_token "gho_faketoken"

  setup do
    original = Application.fetch_env!(:camelot, :registration_enabled)
    on_exit(fn -> Application.put_env(:camelot, :registration_enabled, original) end)
    Application.put_env(:camelot, :registration_enabled, true)
    :ok
  end

  defp user_info(overrides \\ %{}) do
    Map.merge(
      %{
        "sub" => 4711,
        "email" => "octocat@example.com",
        "email_verified" => true,
        "preferred_username" => "octocat"
      },
      overrides
    )
  end

  defp register(info, tokens \\ %{"access_token" => @access_token}) do
    User
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_context(%{private: %{ash_authentication?: true}})
    |> Ash.Changeset.for_create(
      :register_with_github,
      %{user_info: info, oauth_tokens: tokens},
      upsert?: true,
      upsert_identity: :unique_email
    )
    |> Ash.create()
  end

  defp existing_user!(attrs) do
    defaults = %{confirmed_at: DateTime.utc_now()}
    Ash.Seed.seed!(User, Map.merge(defaults, attrs))
  end

  describe "a brand new GitHub account" do
    test "creates a confirmed user with the GitHub id stored" do
      assert {:ok, user} = register(user_info())

      assert to_string(user.email) == "octocat@example.com"
      assert user.github_user_id == "4711"
      assert user.confirmed_at
      assert user.role == :user
    end

    test "generates the default SSH credential" do
      assert {:ok, user} = register(user_info())

      assert [%Credential{kind: :ssh_private_key, name: "default"}] =
               Credential
               |> Ash.Query.filter(user_id == ^user.id)
               |> Ash.read!(authorize?: false)
    end

    test "returns a session token and stashes the GitHub access token" do
      assert {:ok, user} = register(user_info())

      assert is_binary(user.__metadata__.token)
      assert user.__metadata__[:github_access_token] == @access_token
      refute user.__metadata__[:pending_github_email]
    end
  end

  describe "matching an existing account" do
    test "the same email signs in as the same user, without a second row" do
      existing = existing_user!(%{email: "octocat@example.com", role: :admin})

      assert {:ok, user} = register(user_info())

      assert user.id == existing.id
      assert Enum.count(Ash.read!(User, authorize?: false)) == 1
    end

    test "the email match is case-insensitive" do
      existing = existing_user!(%{email: "Octocat@Example.COM"})

      assert {:ok, user} = register(user_info(%{"email" => "octocat@example.com"}))

      assert user.id == existing.id
    end

    test "an email match with no GitHub id backfills the id" do
      existing = existing_user!(%{email: "octocat@example.com"})
      refute existing.github_user_id

      assert {:ok, user} = register(user_info())

      assert user.id == existing.id
      assert user.github_user_id == "4711"
    end

    test "does not clobber role, node label or notification prefs" do
      existing =
        existing_user!(%{
          email: "octocat@example.com",
          role: :admin,
          swarm_node_label: "gpu-1",
          notify_on_done: false
        })

      assert {:ok, user} = register(user_info())

      assert user.id == existing.id
      assert user.role == :admin
      assert user.swarm_node_label == "gpu-1"
      assert user.notify_on_done == false
    end

    test "upserting onto an unconfirmed row is refused" do
      existing_user!(%{email: "octocat@example.com", confirmed_at: nil})

      assert {:error, error} = register(user_info())

      assert Enum.any?(
               Ash.Error.to_error_class(error).errors,
               &match?(%CannotConfirmUnconfirmedUser{}, &1)
             )
    end
  end

  describe "a returning GitHub account whose email changed" do
    setup do
      {:ok, user} = register(user_info())
      %{user: user}
    end

    test "stays the same user, keeps the stored email and reports the new one",
         %{user: user} do
      assert {:ok, again} = register(user_info(%{"email" => "new@example.com"}))

      assert again.id == user.id
      assert to_string(again.email) == "octocat@example.com"
      assert again.__metadata__[:pending_github_email] == "new@example.com"
      assert Enum.count(Ash.read!(User, authorize?: false)) == 1
    end

    test "an unchanged email reports no pending email", %{user: user} do
      assert {:ok, again} = register(user_info())

      assert again.id == user.id
      refute again.__metadata__[:pending_github_email]
    end
  end

  describe "unverified GitHub emails" do
    test "rejects email_verified == false" do
      assert {:error, _} = register(user_info(%{"email_verified" => false}))
      assert Ash.read!(User, authorize?: false) == []
    end

    test "rejects a payload with no email_verified key" do
      assert {:error, _} = register(Map.delete(user_info(), "email_verified"))
    end

    test "rejects a payload whose email key assent pruned away" do
      assert {:error, _} = register(Map.delete(user_info(), "email"))
    end

    test "rejects a payload with no GitHub id" do
      assert {:error, _} = register(Map.delete(user_info(), "sub"))
    end
  end

  describe "invite-only mode" do
    setup do
      Application.put_env(:camelot, :registration_enabled, false)
      :ok
    end

    test "refuses an unknown GitHub account" do
      assert {:error, error} = register(user_info())

      assert Exception.message(error) =~ "invite-only"
      assert Ash.read!(User, authorize?: false) == []
    end

    test "still signs in a known email" do
      existing = existing_user!(%{email: "octocat@example.com"})

      assert {:ok, user} = register(user_info())
      assert user.id == existing.id
    end
  end
end
