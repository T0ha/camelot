defmodule Camelot.Github.JwtTest do
  use ExUnit.Case, async: false

  alias Camelot.Github.Jwt

  setup do
    previous = Application.get_env(:camelot, :github_app)
    on_exit(fn -> Application.put_env(:camelot, :github_app, previous) end)
    :ok
  end

  defp put_app_config(app_id) do
    pem = generate_pem()

    Application.put_env(:camelot, :github_app,
      app_id: app_id,
      slug: "camelot-dev",
      client_id: "Iv1.abc",
      client_secret: "secret",
      private_key: Base.encode64(pem),
      webhook_secret: "whsecret"
    )
  end

  defp generate_pem do
    key = :public_key.generate_key({:rsa, 2_048, 65_537})
    der = :public_key.der_encode(:RSAPrivateKey, key)
    :public_key.pem_encode([{:RSAPrivateKey, der, :not_encrypted}])
  end

  describe "signed_jwt/0" do
    test "signs a JWT carrying the configured app_id as iss, with iat/exp around now" do
      put_app_config("999")

      assert {:ok, token} = Jwt.signed_jwt()
      assert {:ok, claims} = Joken.peek_claims(token)

      assert claims["iss"] == "999"
      now = System.system_time(:second)
      assert claims["iat"] <= now
      assert claims["exp"] > now
    end

    test "returns :not_configured when the App isn't configured" do
      Application.put_env(:camelot, :github_app, [])
      assert Jwt.signed_jwt() == :not_configured
    end
  end
end
