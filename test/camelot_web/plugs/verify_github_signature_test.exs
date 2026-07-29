defmodule CamelotWeb.Plugs.VerifyGithubSignatureTest do
  use CamelotWeb.ConnCase, async: false

  alias CamelotWeb.Plugs.VerifyGithubSignature

  @secret "whsecret"

  setup do
    previous = Application.get_env(:camelot, :github_app)

    Application.put_env(:camelot, :github_app,
      app_id: "123",
      slug: "camelot-dev",
      client_id: "Iv1.abc",
      client_secret: "secret",
      private_key: Base.encode64("not-a-real-key"),
      webhook_secret: @secret
    )

    on_exit(fn -> Application.put_env(:camelot, :github_app, previous) end)
    :ok
  end

  defp sign(body, secret), do: "sha256=" <> (:hmac |> :crypto.mac(:sha256, secret, body) |> Base.encode16(case: :lower))

  defp conn_with_raw_body(body, signature \\ nil) do
    conn =
      :post
      |> build_conn("/github/webhooks", body)
      |> Plug.Conn.assign(:raw_body, body)

    if signature, do: Plug.Conn.put_req_header(conn, "x-hub-signature-256", signature), else: conn
  end

  test "passes a request with a valid signature through" do
    body = ~s({"ok":true})
    conn = conn_with_raw_body(body, sign(body, @secret))

    conn = VerifyGithubSignature.call(conn, [])

    refute conn.halted
  end

  test "halts with 401 on a signature mismatch" do
    body = ~s({"ok":true})
    conn = conn_with_raw_body(body, sign(body, "wrong-secret"))

    conn = VerifyGithubSignature.call(conn, [])

    assert conn.halted
    assert conn.status == 401
  end

  test "halts with 401 when the signature header is missing" do
    conn = conn_with_raw_body(~s({"ok":true}))

    conn = VerifyGithubSignature.call(conn, [])

    assert conn.halted
    assert conn.status == 401
  end

  test "halts with 401 when the App isn't configured" do
    Application.put_env(:camelot, :github_app, [])
    body = ~s({"ok":true})
    conn = conn_with_raw_body(body, sign(body, @secret))

    conn = VerifyGithubSignature.call(conn, [])

    assert conn.halted
    assert conn.status == 401
  end
end
