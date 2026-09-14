defmodule CamelotWeb.Plugs.GithubAuthGate do
  @moduledoc """
  Turns away GitHub sign-in requests on instances where the
  GitHub App isn't configured.

  The strategy is declared statically on
  `Camelot.Accounts.User`, and AshAuthentication's overrides
  are resolved at compile time, so the "Log in with GitHub"
  button renders even when `GITHUB_APP_*` is unset. Without
  this plug those users would get an opaque
  `MissingSecret` error instead of an explanation.

  Mirrors `CamelotWeb.Plugs.RegistrationGate`.
  """

  import Phoenix.Controller, only: [put_flash: 3, redirect: 2]
  import Plug.Conn

  alias Camelot.Github.AppConfig

  @request_path ["auth", "user", "github"]
  @callback_path ["auth", "user", "github", "callback"]

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(%Plug.Conn{path_info: @request_path} = conn, _opts), do: gate(conn)
  def call(%Plug.Conn{path_info: @callback_path} = conn, _opts), do: gate(conn)
  def call(conn, _opts), do: conn

  defp gate(conn) do
    if AppConfig.configured?() do
      conn
    else
      deny(conn)
    end
  end

  defp deny(conn) do
    conn
    |> put_flash(:error, "GitHub sign-in isn't configured on this instance.")
    |> redirect(to: "/sign-in")
    |> halt()
  end
end
