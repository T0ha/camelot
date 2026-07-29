defmodule CamelotWeb.Plugs.VerifyGithubSignature do
  @moduledoc """
  Verifies GitHub's `X-Hub-Signature-256` HMAC-SHA256
  header against the raw request body (stashed by
  `CamelotWeb.Plugs.CacheBodyReader`) and the configured
  webhook secret. Halts with 401 on any mismatch, missing
  header, or unconfigured App.
  """
  import Plug.Conn

  alias Camelot.Github.AppConfig

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    with {:ok, %{webhook_secret: secret}} <- AppConfig.fetch(),
         [signature] <- get_req_header(conn, "x-hub-signature-256"),
         body when is_binary(body) <- conn.assigns[:raw_body],
         true <- valid_signature?(secret, body, signature) do
      conn
    else
      _ -> conn |> send_resp(401, "invalid signature") |> halt()
    end
  end

  defp valid_signature?(secret, body, "sha256=" <> hex_digest) do
    expected =
      :hmac
      |> :crypto.mac(:sha256, secret, body)
      |> Base.encode16(case: :lower)

    Plug.Crypto.secure_compare(expected, hex_digest)
  end

  defp valid_signature?(_secret, _body, _signature), do: false
end
