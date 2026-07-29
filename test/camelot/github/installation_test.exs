defmodule Camelot.Github.InstallationTest do
  use Camelot.DataCase, async: true

  alias Camelot.Github.Installation
  alias Camelot.Projects.Project

  require Ash.Query

  defp unique_installation_id, do: System.unique_integer([:positive])

  describe ":upsert action" do
    test "creates a new row" do
      id = unique_installation_id()

      assert {:ok, installation} =
               Ash.create(Installation, %{
                 installation_id: id,
                 account_login: "acme",
                 account_type: :organization
               })

      assert installation.installation_id == id
      assert installation.account_login == "acme"
      assert installation.account_type == :organization
      assert is_nil(installation.suspended_at)
    end

    test "upserts by installation_id, updating login/type in place" do
      id = unique_installation_id()

      {:ok, first} =
        Ash.create(Installation, %{
          installation_id: id,
          account_login: "old-login",
          account_type: :user
        })

      {:ok, second} =
        Ash.create(Installation, %{
          installation_id: id,
          account_login: "new-login",
          account_type: :organization
        })

      assert first.id == second.id
      assert second.account_login == "new-login"
      assert second.account_type == :organization
    end
  end

  describe ":suspend / :unsuspend actions" do
    test "suspend stamps suspended_at, unsuspend clears it" do
      {:ok, installation} =
        Ash.create(Installation, %{
          installation_id: unique_installation_id(),
          account_login: "acme",
          account_type: :organization
        })

      {:ok, suspended} = Ash.update(installation, %{}, action: :suspend)
      assert %DateTime{} = suspended.suspended_at

      {:ok, unsuspended} = Ash.update(suspended, %{}, action: :unsuspend)
      assert is_nil(unsuspended.suspended_at)
    end
  end

  describe "destroy" do
    test "nilifies the linked project's github_installation_id" do
      {:ok, installation} =
        Ash.create(Installation, %{
          installation_id: unique_installation_id(),
          account_login: "acme",
          account_type: :organization
        })

      {:ok, project} =
        Ash.create(
          Project,
          %{name: "proj-#{System.unique_integer([:positive])}", github_installation_id: installation.id},
          actor: user!()
        )

      Ash.destroy!(installation)

      {:ok, reloaded} =
        Project
        |> Ash.Query.filter(id == ^project.id)
        |> Ash.read_one()

      assert is_nil(reloaded.github_installation_id)
    end
  end
end
