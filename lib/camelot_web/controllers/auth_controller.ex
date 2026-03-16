defmodule CamelotWeb.AuthController do
  @moduledoc """
  Handles authentication callbacks from
  AshAuthentication strategies.
  """
  use CamelotWeb, :controller
  use AshAuthentication.Phoenix.Controller

  @spec success(
          Plug.Conn.t(),
          {atom(), atom()},
          Ash.Resource.record(),
          String.t() | nil
        ) :: Plug.Conn.t()
  def success(conn, _activity, user, _token) do
    conn
    |> store_in_session(user)
    |> assign(:current_user, user)
    |> redirect(to: ~p"/")
  end

  @spec failure(
          Plug.Conn.t(),
          {atom(), atom()},
          any()
        ) :: Plug.Conn.t()
  def failure(conn, _activity, _reason) do
    conn
    |> put_flash(:error, "Authentication failed")
    |> redirect(to: ~p"/sign-in")
  end

  @spec sign_out(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def sign_out(conn, _params) do
    conn
    |> clear_session(:camelot)
    |> redirect(to: ~p"/sign-in")
  end
end
