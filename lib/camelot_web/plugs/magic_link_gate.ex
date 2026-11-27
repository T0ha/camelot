defmodule CamelotWeb.Plugs.MagicLinkGate do
  @moduledoc """
  Turns away magic-link requests and token sign-ins when
  `:magic_link_enabled` is `false`.

  The strategy is declared statically on `Camelot.Accounts.User`,
  so it is enforced here at runtime. Links mailed before the switch
  was flipped stop working too. The LiveView submit path never hits
  HTTP; `Camelot.Accounts.User.Senders.SendMagicLink` covers it.

  Mirrors `CamelotWeb.Plugs.GithubAuthGate`.
  """

  import Phoenix.Controller, only: [put_flash: 3, redirect: 2]
  import Plug.Conn

  alias Camelot.Accounts.MagicLink

  @request_path ["auth", "user", "magic_link", "request"]
  @sign_in_path ["auth", "user", "magic_link"]

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(%Plug.Conn{method: "POST", path_info: @request_path} = conn, _), do: gate(conn, MagicLink.enabled?())

  def call(%Plug.Conn{path_info: @sign_in_path} = conn, _), do: gate(conn, MagicLink.enabled?())

  def call(%Plug.Conn{path_info: ["magic_link", _token]} = conn, _), do: gate(conn, MagicLink.enabled?())

  def call(conn, _opts), do: conn

  defp gate(conn, true), do: conn

  defp gate(conn, false) do
    conn
    |> put_flash(:error, "Email sign-in is disabled on this instance.")
    |> redirect(to: "/sign-in")
    |> halt()
  end
end
