defmodule Camelot.Github.InstallationTokenCacheTest do
  use Camelot.DataCase, async: false

  alias Camelot.Github.Installation
  alias Camelot.Github.InstallationTokenCache

  setup do
    previous = Application.get_env(:camelot, :github_app)
    on_exit(fn -> Application.put_env(:camelot, :github_app, previous) end)
    :ok
  end

  defp unique_installation_id do
    System.unique_integer([:positive])
  end

  defp put_app_configured do
    Application.put_env(:camelot, :github_app,
      app_id: "123",
      slug: "camelot-dev",
      client_id: "Iv1.abc",
      client_secret: "secret",
      private_key: Base.encode64("not-a-real-key"),
      webhook_secret: "whsecret"
    )
  end

  describe "fetch/1" do
    test "returns a cached token without minting when it has plenty of ttl left" do
      id = unique_installation_id()
      far_future = DateTime.add(DateTime.utc_now(), 3_600, :second)
      :ets.insert(InstallationTokenCache, {id, "cached-token", far_future})

      assert {:ok, "cached-token"} = InstallationTokenCache.fetch(id)
    end

    test "returns :not_configured without a network call when the App isn't set up" do
      Application.put_env(:camelot, :github_app, [])
      assert InstallationTokenCache.fetch(unique_installation_id()) == {:error, :not_configured}
    end

    test "returns :not_found when the App is configured but no such installation exists" do
      put_app_configured()
      assert InstallationTokenCache.fetch(unique_installation_id()) == {:error, :not_found}
    end

    test "returns :suspended without a network call for a suspended installation" do
      put_app_configured()
      id = unique_installation_id()

      {:ok, installation} =
        Ash.create(Installation, %{
          installation_id: id,
          account_login: "acme",
          account_type: :organization
        })

      {:ok, _} = Ash.update(installation, %{}, action: :suspend)

      assert InstallationTokenCache.fetch(id) == {:error, :suspended}
    end

    test "an expired cache entry is treated as a miss" do
      put_app_configured()
      id = unique_installation_id()
      past = DateTime.add(DateTime.utc_now(), -10, :second)
      :ets.insert(InstallationTokenCache, {id, "stale-token", past})

      # No installation row exists for this id, so the mint path
      # short-circuits at :not_found instead of reaching the network —
      # proves the stale entry was NOT returned as-is.
      assert InstallationTokenCache.fetch(id) == {:error, :not_found}
    end
  end
end
