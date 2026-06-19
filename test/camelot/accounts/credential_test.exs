defmodule Camelot.Accounts.CredentialTest do
  use Camelot.DataCase, async: true

  alias Camelot.Accounts.Credential

  require Ash.Query

  describe ":value attribute" do
    test "preserves trailing whitespace verbatim across create + read" do
      # OpenSSH private keys end in `\n`; Ash's default trim?: true on
      # :string silently strips it and the resulting file is rejected
      # by OpenSSH as "invalid format". This guards against regression.
      user = user!()

      value = "-----BEGIN OPENSSH PRIVATE KEY-----\nb64data==\n-----END OPENSSH PRIVATE KEY-----\n"

      {:ok, cred} =
        Ash.create(Credential, %{
          user_id: user.id,
          kind: :ssh_private_key,
          name: "default",
          value: value
        })

      {:ok, reloaded} =
        Credential
        |> Ash.Query.filter(id == ^cred.id)
        |> Ash.Query.load(:value)
        |> Ash.read_one()

      assert reloaded.value == value
      assert String.ends_with?(reloaded.value, "\n")
    end
  end

  describe ":rotate action" do
    test "replaces value, stamps rotated_at, preserves untouched metadata" do
      user = user!()

      {:ok, cred} =
        Ash.create(Credential, %{
          user_id: user.id,
          kind: :ssh_private_key,
          name: "default",
          value: "old-private",
          metadata: %{
            "public_key" => "old-pub",
            "fingerprint" => "SHA256:old",
            "algorithm" => "ed25519",
            "source" => "server_generated"
          }
        })

      {:ok, rotated} =
        cred
        |> Ash.Changeset.for_update(:rotate, %{value: "new-private"})
        |> Ash.update()

      # rotated_at appears
      assert {:ok, _, _} = DateTime.from_iso8601(rotated.metadata["rotated_at"])
      # untouched fields stay
      assert rotated.metadata["public_key"] == "old-pub"
      assert rotated.metadata["source"] == "server_generated"
    end

    test "accepts a metadata argument that overrides specific keys " <>
           "(public_key, fingerprint, algorithm) atomically with value" do
      user = user!()

      {:ok, cred} =
        Ash.create(Credential, %{
          user_id: user.id,
          kind: :ssh_private_key,
          name: "default",
          value: "old",
          metadata: %{
            "public_key" => "old-pub",
            "fingerprint" => "SHA256:old",
            "algorithm" => "ed25519",
            "source" => "server_generated"
          }
        })

      {:ok, rotated} =
        cred
        |> Ash.Changeset.for_update(:rotate, %{
          value: "new-private",
          metadata: %{
            "public_key" => "new-pub",
            "fingerprint" => "SHA256:new",
            "algorithm" => "ed25519"
          }
        })
        |> Ash.update()

      assert rotated.metadata["public_key"] == "new-pub"
      assert rotated.metadata["fingerprint"] == "SHA256:new"
      # untouched key survives the merge
      assert rotated.metadata["source"] == "server_generated"
      # rotated_at still stamped
      assert {:ok, _, _} = DateTime.from_iso8601(rotated.metadata["rotated_at"])
    end
  end
end
