defmodule CamelotWeb.GithubWebhookControllerTest do
  use CamelotWeb.ConnCase, async: true

  alias Camelot.Github.Installation
  alias CamelotWeb.GithubWebhookController

  require Ash.Query

  defp unique_installation_id, do: System.unique_integer([:positive])

  defp event_conn(event, params) do
    :post
    |> build_conn("/github/webhooks", params)
    |> Plug.Conn.put_req_header("x-github-event", event)
  end

  defp installation_payload(id, action, overrides \\ %{}) do
    %{
      "action" => action,
      "installation" => Map.merge(%{"id" => id, "account" => %{"login" => "acme", "type" => "Organization"}}, overrides)
    }
  end

  test "installation created upserts a row" do
    id = unique_installation_id()
    params = installation_payload(id, "created")

    conn = GithubWebhookController.create(event_conn("installation", params), params)

    assert conn.status == 200
    assert {:ok, %Installation{account_login: "acme"}} = fetch(id)
  end

  test "installation suspend/unsuspend toggles suspended_at" do
    id = unique_installation_id()
    created = installation_payload(id, "created")
    GithubWebhookController.create(event_conn("installation", created), created)

    suspend = installation_payload(id, "suspend")
    GithubWebhookController.create(event_conn("installation", suspend), suspend)
    assert {:ok, %Installation{suspended_at: %DateTime{}}} = fetch(id)

    unsuspend = installation_payload(id, "unsuspend")
    GithubWebhookController.create(event_conn("installation", unsuspend), unsuspend)
    assert {:ok, %Installation{suspended_at: nil}} = fetch(id)
  end

  test "installation deleted removes the row" do
    id = unique_installation_id()
    created = installation_payload(id, "created")
    GithubWebhookController.create(event_conn("installation", created), created)

    deleted = installation_payload(id, "deleted")
    GithubWebhookController.create(event_conn("installation", deleted), deleted)

    assert {:ok, nil} = fetch(id)
  end

  test "unknown events are acknowledged and ignored" do
    conn = GithubWebhookController.create(event_conn("ping", %{}), %{})
    assert conn.status == 200
  end

  defp fetch(installation_id) do
    Installation
    |> Ash.Query.filter(installation_id == ^installation_id)
    |> Ash.read_one()
  end
end
