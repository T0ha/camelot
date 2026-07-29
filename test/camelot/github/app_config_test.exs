defmodule Camelot.Github.AppConfigTest do
  use ExUnit.Case, async: false

  alias Camelot.Github.AppConfig

  @valid [
    app_id: "123",
    slug: "camelot-dev",
    client_id: "Iv1.abc",
    client_secret: "secret",
    private_key: Base.encode64("-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----\n"),
    webhook_secret: "whsecret"
  ]

  setup do
    previous = Application.get_env(:camelot, :github_app)
    on_exit(fn -> Application.put_env(:camelot, :github_app, previous) end)
    :ok
  end

  describe "fetch/0" do
    test "returns {:ok, config} with the private key base64-decoded when fully configured" do
      Application.put_env(:camelot, :github_app, @valid)

      assert {:ok, config} = AppConfig.fetch()
      assert config.app_id == "123"
      assert config.slug == "camelot-dev"
      assert config.private_key == "-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----\n"
    end

    test "returns :not_configured when unset entirely" do
      Application.put_env(:camelot, :github_app, [])
      assert AppConfig.fetch() == :not_configured
    end

    test "returns :not_configured when partially configured" do
      Application.put_env(:camelot, :github_app, Keyword.put(@valid, :client_secret, nil))
      assert AppConfig.fetch() == :not_configured
    end

    test "returns :not_configured when a required field is blank" do
      Application.put_env(:camelot, :github_app, Keyword.put(@valid, :app_id, ""))
      assert AppConfig.fetch() == :not_configured
    end

    test "returns :not_configured when the private key isn't valid base64" do
      Application.put_env(:camelot, :github_app, Keyword.put(@valid, :private_key, "not base64!!"))
      assert AppConfig.fetch() == :not_configured
    end
  end

  describe "configured?/0" do
    test "true when fetch/0 succeeds" do
      Application.put_env(:camelot, :github_app, @valid)
      assert AppConfig.configured?()
    end

    test "false otherwise" do
      Application.put_env(:camelot, :github_app, [])
      refute AppConfig.configured?()
    end
  end
end
