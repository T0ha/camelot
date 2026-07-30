defmodule CamelotWeb.GithubWebhookController do
  @moduledoc """
  Receives GitHub App webhook events, verified upstream by
  `CamelotWeb.Plugs.VerifyGithubSignature`. Only
  `installation` lifecycle events are handled today
  (`created`/`unsuspend`/`suspend`/`deleted`); everything
  else is acknowledged and ignored.
  """
  use CamelotWeb, :controller

  alias Camelot.Github.InstallationSync

  require Logger

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params) do
    conn
    |> get_req_header("x-github-event")
    |> handle_event(params)

    send_resp(conn, 200, "")
  end

  defp handle_event(["installation"], %{"action" => "created", "installation" => gh}) do
    InstallationSync.upsert(gh)
  end

  defp handle_event(["installation"], %{"action" => "unsuspend", "installation" => gh}) do
    InstallationSync.unsuspend(gh)
  end

  defp handle_event(["installation"], %{"action" => "suspend", "installation" => gh}) do
    InstallationSync.suspend(gh)
  end

  defp handle_event(["installation"], %{"action" => "deleted", "installation" => gh}) do
    InstallationSync.delete(gh)
  end

  defp handle_event(event, _params) do
    Logger.debug("GithubWebhookController: ignoring event #{inspect(event)}")
    :ok
  end
end
