defmodule Camelot.Accounts.User.Changes.EnsureDefaultSshKeyTest do
  use Camelot.DataCase, async: false

  alias Ash.Resource.Info, as: ResourceInfo
  alias Camelot.Accounts.Credential
  alias Camelot.Accounts.User
  alias Camelot.Accounts.User.Changes.EnsureDefaultSshKey

  require Ash.Query

  describe ":create_user action" do
    test "generates a default SSH credential after user creation" do
      admin = Ash.Seed.seed!(User, %{email: "admin@e.com", role: :admin})

      {:ok, user} =
        User
        |> Ash.Changeset.for_create(
          :create_user,
          %{email: "new@e.com", role: :user},
          actor: admin
        )
        |> Ash.create()

      creds = ssh_credentials_for(user.id)

      assert [cred] = creds
      assert cred.kind == :ssh_private_key
      assert cred.name == "default"

      assert %{
               "public_key" => "ssh-ed25519 " <> _,
               "fingerprint" => "SHA256:" <> _,
               "algorithm" => "ed25519",
               "source" => "server_generated",
               "generated_at" => _
             } = cred.metadata
    end
  end

  describe "resource-level wiring" do
    test "the change is attached on: [:create] so it fires for both " <>
           ":create_user and the magic-link upsert" do
      changes = ResourceInfo.changes(User)

      assert Enum.any?(changes, fn change ->
               change.change == {EnsureDefaultSshKey, []} and
                 change.on == [:create]
             end),
             """
             EnsureDefaultSshKey should be a resource-level change with \
             on: [:create] so the magic-link auto-generated \
             :sign_in_with_magic_link create action triggers it for new \
             registrations. Configured changes: #{inspect(changes)}
             """
    end
  end

  describe "ensure_default_for/1" do
    test "creates a key when none exists (legacy-user backfill path)" do
      user = user!()
      assert ssh_credentials_for(user.id) == []

      assert {:ok, cred} = EnsureDefaultSshKey.ensure_default_for(user.id)
      assert cred.kind == :ssh_private_key
      assert cred.name == "default"
    end

    test "is idempotent — second call returns the existing credential" do
      user = user!()

      {:ok, first} = EnsureDefaultSshKey.ensure_default_for(user.id)
      {:ok, second} = EnsureDefaultSshKey.ensure_default_for(user.id)

      assert first.id == second.id
      assert length(ssh_credentials_for(user.id)) == 1
    end
  end

  defp ssh_credentials_for(user_id) do
    Credential
    |> Ash.Query.filter(user_id == ^user_id and kind == :ssh_private_key)
    |> Ash.read!()
  end
end
