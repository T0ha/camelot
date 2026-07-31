defmodule Camelot.Github.InstallationSyncTest do
  use Camelot.DataCase, async: true

  alias Camelot.Github.Installation
  alias Camelot.Github.InstallationSync

  require Ash.Query

  defp unique_installation_id, do: System.unique_integer([:positive])

  defp gh_payload(id, overrides \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "account" => %{"login" => "acme", "type" => "Organization"}
      },
      overrides
    )
  end

  describe "upsert/1" do
    test "creates a row, normalizing the account type" do
      id = unique_installation_id()

      assert {:ok, installation} = InstallationSync.upsert(gh_payload(id))
      assert installation.installation_id == id
      assert installation.account_login == "acme"
      assert installation.account_type == :organization
    end

    test "a User account type normalizes to :user" do
      id = unique_installation_id()
      payload = gh_payload(id, %{"account" => %{"login" => "octocat", "type" => "User"}})

      assert {:ok, installation} = InstallationSync.upsert(payload)
      assert installation.account_type == :user
    end
  end

  describe "suspend/1 and unsuspend/1" do
    test "toggle suspended_at on the matching installation" do
      id = unique_installation_id()
      {:ok, _} = InstallationSync.upsert(gh_payload(id))

      :ok = InstallationSync.suspend(gh_payload(id))
      assert {:ok, %Installation{suspended_at: %DateTime{}}} = fetch(id)

      :ok = InstallationSync.unsuspend(gh_payload(id))
      assert {:ok, %Installation{suspended_at: nil}} = fetch(id)
    end

    test "no-ops when the installation isn't known" do
      assert :ok = InstallationSync.suspend(gh_payload(unique_installation_id()))
    end
  end

  describe "delete/1" do
    test "removes the matching installation row" do
      id = unique_installation_id()
      {:ok, _} = InstallationSync.upsert(gh_payload(id))

      :ok = InstallationSync.delete(gh_payload(id))

      assert {:ok, nil} = fetch(id)
    end

    test "no-ops when the installation isn't known" do
      assert :ok = InstallationSync.delete(gh_payload(unique_installation_id()))
    end
  end

  defp fetch(installation_id) do
    Installation
    |> Ash.Query.filter(installation_id == ^installation_id)
    |> Ash.read_one(authorize?: false)
  end
end
