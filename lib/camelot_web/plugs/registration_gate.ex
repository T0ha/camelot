defmodule CamelotWeb.Plugs.RegistrationGate do
  @moduledoc """
  Blocks magic-link requests from unknown emails when
  `:registration_enabled` is `false`. Existing users still
  receive sign-in links normally — only first-time email
  submissions get rejected.
  """

  import Phoenix.Controller, only: [put_flash: 3, redirect: 2]
  import Plug.Conn

  alias Camelot.Accounts.User

  require Ash.Query

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

  defp gate(conn, "") do
    deny(conn)
  end

  defp gate(conn, email) do
    User
    |> Ash.Query.filter(email == ^email)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %User{}} -> conn
      _ -> deny(conn)
    end
  end

  defp deny(conn) do
    conn
    |> put_flash(
      :error,
      "Registration is invite-only. Contact your administrator."
    )
    |> redirect(to: "/sign-in")
    |> halt()
  end
end
