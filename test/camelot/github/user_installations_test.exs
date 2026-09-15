defmodule Camelot.Github.UserInstallationsTest do
  use Camelot.DataCase, async: false

  alias Camelot.Accounts.User
  alias Camelot.Github.Installation
  alias Camelot.Github.UserInstallations

  require Ash.Query

  setup do
    previous = Application.get_env(:camelot, :github_app)
    on_exit(fn -> Application.put_env(:camelot, :github_app, previous) end)
    :ok
  end

  defp seed_user!(email) do
    Ash.Seed.seed!(User, %{email: email, confirmed_at: DateTime.utc_now()})
  end

  defp payload(id, overrides \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "account" => %{"login" => "octocat", "type" => "User"}
      },
      overrides
    )
  end

  defp installation!(installation_id) do
    Installation
    |> Ash.Query.filter(installation_id == ^installation_id)
    |> Ash.read_one!(authorize?: false)
  end

  defp unique_id, do: System.unique_integer([:positive])

  describe "link/2" do
    test "creates rows owned by the user" do
      user = seed_user!("linker@example.com")
      id = unique_id()

      assert :ok = UserInstallations.link([payload(id)], user)

      installation = installation!(id)
      assert installation.user_id == user.id
      assert installation.account_login == "octocat"
      assert installation.account_type == :user
    end

    test "links an organization installation" do
      user = seed_user!("org@example.com")
      id = unique_id()

      payload =
        payload(id, %{"account" => %{"login" => "acme", "type" => "Organization"}})

      assert :ok = UserInstallations.link([payload], user)
      assert installation!(id).account_type == :organization
    end

    test "is idempotent" do
      user = seed_user!("idem@example.com")
      id = unique_id()

      assert :ok = UserInstallations.link([payload(id)], user)
      assert :ok = UserInstallations.link([payload(id)], user)

      assert [_one] =
               Installation
               |> Ash.Query.filter(installation_id == ^id)
               |> Ash.read!(authorize?: false)
    end

    test "skips an installation owned by someone else and links the rest" do
      owner = seed_user!("owner@example.com")
      newcomer = seed_user!("newcomer@example.com")
      taken = unique_id()
      free = unique_id()

      assert :ok = UserInstallations.link([payload(taken)], owner)
      assert :ok = UserInstallations.link([payload(taken), payload(free)], newcomer)

      assert installation!(taken).user_id == owner.id
      assert installation!(free).user_id == newcomer.id
    end

    test "handles an empty list" do
      user = seed_user!("empty@example.com")
      assert :ok = UserInstallations.link([], user)
    end
  end

  describe "list/1" do
    test "refuses a nil access token without touching the network" do
      assert UserInstallations.list(nil) == {:error, :no_access_token}
    end

    test "refuses when the GitHub App isn't configured" do
      Application.put_env(:camelot, :github_app, [])

      assert UserInstallations.list("gho_token") == {:error, :not_configured}
    end
  end

  describe "sync/2" do
    test "passes the list/1 error through" do
      user = seed_user!("sync@example.com")

      assert UserInstallations.sync(nil, user) == {:error, :no_access_token}
    end
  end
end
