defmodule CamelotWeb.SessionDownloadController do
  @moduledoc """
  Serves a session's persisted `output_log` as a downloadable
  NDJSON file, scoped the same way `CamelotWeb.TaskLive` scopes
  task access.
  """
  use CamelotWeb, :controller

  alias Camelot.Accounts.User
  alias Camelot.Agents.Session
  alias CamelotWeb.Scope

  require Ash.Query

  @spec download(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def download(conn, %{"id" => id}) do
    case load_or_forbid(id, conn.assigns[:current_user]) do
      {:ok, session} ->
        conn
        |> put_resp_content_type("application/x-ndjson", nil)
        |> put_resp_header(
          "content-disposition",
          ~s(attachment; filename="session-#{session.id}.ndjson")
        )
        |> send_resp(200, session.output_log || "")

      :forbidden ->
        conn
        |> put_status(:not_found)
        |> put_view(CamelotWeb.ErrorHTML)
        |> render(:"404")
    end
  end

  defp load_or_forbid(_id, nil), do: :forbidden

  defp load_or_forbid(id, %User{role: :admin}) do
    case Ash.get(Session, id) do
      {:ok, session} -> {:ok, session}
      _ -> :forbidden
    end
  end

  defp load_or_forbid(id, %User{} = user) do
    case Session
         |> Ash.Query.filter(id == ^id)
         |> Scope.scope_sessions(user)
         |> Ash.read_one() do
      {:ok, %Session{} = session} -> {:ok, session}
      _ -> :forbidden
    end
  end
end
