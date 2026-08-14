defmodule CamelotWeb.TaskAttachmentController do
  @moduledoc """
  Serves a `TaskAttachment`'s blob.

  Two ways in: a logged-in session user who is a member of the
  task's project (or an admin), or a signed `?token=` — how the
  agent container (no browser session) fetches the file, since
  `download_url/1` is embedded in its `ATTACHMENTS_JSON` env var.
  """
  use CamelotWeb, :controller

  alias Camelot.Accounts.User
  alias Camelot.Board.AttachmentStore
  alias Camelot.Board.TaskAttachment

  require Ash.Query

  @token_salt "task_attachment"
  @token_max_age to_timeout(day: 1)

  @spec download(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def download(conn, %{"id" => id} = params) do
    case authorized_attachment(id, conn.assigns[:current_user], params["token"]) do
      {:ok, attachment} -> send_attachment(conn, attachment)
      :error -> conn |> put_status(:not_found) |> halt()
    end
  end

  @doc """
  Signs a token embedding `attachment_id`, for use in a
  `?token=` download URL that doesn't require a browser session
  (e.g. the URL handed to an agent container).
  """
  @spec sign_token(Ecto.UUID.t()) :: String.t()
  def sign_token(attachment_id) do
    Phoenix.Token.sign(CamelotWeb.Endpoint, @token_salt, attachment_id)
  end

  defp authorized_attachment(id, current_user, token) do
    with :error <- authorized_by_session(id, current_user) do
      authorized_by_token(id, token)
    end
  end

  defp authorized_by_session(_id, nil), do: :error

  defp authorized_by_session(id, %User{role: :admin}) do
    case Ash.get(TaskAttachment, id, load: [task: [:project]]) do
      {:ok, attachment} -> {:ok, attachment}
      _ -> :error
    end
  end

  defp authorized_by_session(id, %User{} = user) do
    TaskAttachment
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.filter(exists(task.project.memberships, user_id == ^user.id))
    |> Ash.Query.load(task: [:project])
    |> Ash.read_one()
    |> case do
      {:ok, %TaskAttachment{} = attachment} -> {:ok, attachment}
      _ -> :error
    end
  end

  defp authorized_by_token(_id, nil), do: :error

  defp authorized_by_token(id, token) do
    with {:ok, ^id} <- Phoenix.Token.verify(CamelotWeb.Endpoint, @token_salt, token, max_age: @token_max_age),
         {:ok, attachment} <- Ash.get(TaskAttachment, id) do
      {:ok, attachment}
    else
      _ -> :error
    end
  end

  defp send_attachment(conn, %TaskAttachment{} = attachment) do
    case AttachmentStore.download_url(attachment.storage_key) do
      {:local, path} ->
        send_download(conn, {:file, path},
          filename: attachment.filename,
          content_type: attachment.content_type || "application/octet-stream"
        )

      {:ok, url} ->
        redirect(conn, external: url)
    end
  end
end
