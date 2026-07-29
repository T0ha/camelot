defmodule CamelotWeb.Plugs.CacheBodyReader do
  @moduledoc """
  `Plug.Parsers` body reader that stashes the raw request
  body on the conn before parsing. `VerifyGithubSignature`
  needs to HMAC over the exact bytes GitHub signed — the
  parsed-then-re-encoded JSON would not byte-for-byte
  match what GitHub hashed.
  """

  @spec read_body(Plug.Conn.t(), keyword()) :: {:ok, binary(), Plug.Conn.t()}
  def read_body(conn, opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn, opts)
    {:ok, body, Plug.Conn.assign(conn, :raw_body, body)}
  end
end
