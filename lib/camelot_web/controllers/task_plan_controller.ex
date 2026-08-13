defmodule CamelotWeb.TaskPlanController do
  @moduledoc """
  Serves a task's plan document as a downloadable Markdown
  file, scoped the same way `CamelotWeb.TaskLive` scopes task
  access. Prefers `full_plan` (the complete document captured
  from the agent's plan file) and falls back to `plan`.
  """
  use CamelotWeb, :controller

  alias Camelot.Accounts.User
  alias Camelot.Board.Task
  alias CamelotWeb.Scope

  require Ash.Query

  @spec download(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def download(conn, %{"id" => id}) do
    with {:ok, task} <- load_or_forbid(id, conn.assigns[:current_user]),
         plan when is_binary(plan) <- task.full_plan || task.plan do
      conn
      |> put_resp_content_type("text/markdown", "utf-8")
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="task-#{task.id}-plan.md")
      )
      |> send_resp(200, plan)
    else
      _ ->
        conn
        |> put_status(:not_found)
        |> put_view(CamelotWeb.ErrorHTML)
        |> render(:"404")
    end
  end

  defp load_or_forbid(_id, nil), do: :forbidden

  defp load_or_forbid(id, %User{role: :admin}) do
    case Ash.get(Task, id) do
      {:ok, task} -> {:ok, task}
      _ -> :forbidden
    end
  end

  defp load_or_forbid(id, %User{} = user) do
    case Task
         |> Ash.Query.filter(id == ^id)
         |> Scope.scope_tasks(user)
         |> Ash.read_one() do
      {:ok, %Task{} = task} -> {:ok, task}
      _ -> :forbidden
    end
  end
end
