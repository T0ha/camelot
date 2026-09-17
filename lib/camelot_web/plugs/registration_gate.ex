defmodule CamelotWeb.Plugs.RegistrationGate do
  @moduledoc """
  Blocks magic-link requests from unknown emails when
  `:registration_enabled` is `false`. Existing users still
  receive sign-in links normally — only first-time email
  submissions get rejected.

  The GitHub sign-in equivalent lives in
  `Camelot.Accounts.User.Changes.GateGithubRegistration`;
  both report the same wording.
  """

  import Phoenix.Controller, only: [put_flash: 3, redirect: 2]
  import Plug.Conn

  alias Camelot.Accounts.Errors.RegistrationDisabled
  alias Camelot.Accounts.UserLookup

  @magic_link_request_path ["auth", "user", "magic_link", "request"]

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(%Plug.Conn{method: "POST", path_info: @magic_link_request_path} = conn, _opts) do
    if Application.fetch_env!(:camelot, :registration_enabled) do
      conn
    else
      gate(conn, submitted_email(conn))
    end
  end

  def call(conn, _opts), do: conn

  defp submitted_email(conn) do
    email = get_in(conn.params, ["user", "email"]) || ""
    email |> to_string() |> String.downcase()
  end

  defp gate(conn, email) do
    case UserLookup.fetch_by_email(email) do
      {:ok, _user} -> conn
      :not_found -> deny(conn)
    end
  end

  defp deny(conn) do
    conn
    |> put_flash(:error, RegistrationDisabled.text())
    |> redirect(to: "/sign-in")
    |> halt()
  end
end
