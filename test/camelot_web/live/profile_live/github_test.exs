defmodule CamelotWeb.ProfileLive.GithubTest do
  use CamelotWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Camelot.Github.Installation

  require Ash.Query

  setup :register_and_log_in_user

  setup do
    previous = Application.get_env(:camelot, :github_app)
    on_exit(fn -> Application.put_env(:camelot, :github_app, previous) end)
    :ok
  end

  test "renders its own heading and page title", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/profile/github")

    assert has_element?(view, "h1", "GitHub")
    assert page_title(view) =~ "GitHub"
  end

  test "ignores unrelated messages without crashing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/profile/github")

    send(view.pid, {:some_unexpected_message, :payload})

    assert render(view) =~ "GitHub"
  end

  test "warns when no GitHub App is configured for this deployment", %{conn: conn} do
    Application.put_env(:camelot, :github_app, [])

    {:ok, _view, html} = live(conn, ~p"/profile/github")
    assert html =~ "No GitHub App is configured"
  end

  test "shows a connect link when configured but not connected", %{conn: conn} do
    put_app_configured()

    {:ok, _view, html} = live(conn, ~p"/profile/github")
    assert html =~ "Connect GitHub App"
    refute html =~ "Disconnect"
  end

  test "shows the connected account and a disconnect button when linked", %{
    conn: conn,
    user: user
  } do
    put_app_configured()
    link_installation!(user, "acme-org")

    {:ok, _view, html} = live(conn, ~p"/profile/github")
    assert html =~ "acme-org"
    assert html =~ "Disconnect"
    assert html =~ "Connect another organization"
  end

  test "connecting two orgs renders both in the list", %{conn: conn, user: user} do
    put_app_configured()
    link_installation!(user, "acme-org")
    link_installation!(user, "other-org")

    {:ok, _view, html} = live(conn, ~p"/profile/github")
    assert html =~ "acme-org"
    assert html =~ "other-org"
  end

  test "disconnecting one org leaves the other connected and visible", %{
    conn: conn,
    user: user
  } do
    put_app_configured()
    acme = link_installation!(user, "acme-org")
    link_installation!(user, "other-org")

    {:ok, view, _html} = live(conn, ~p"/profile/github")

    html =
      view
      |> element("button[phx-value-id='#{acme.id}']")
      |> render_click()

    assert html =~ "GitHub App disconnected"
    refute html =~ "acme-org"
    assert html =~ "other-org"

    assert Installation
           |> Ash.Query.filter(user_id == ^user.id)
           |> Ash.read!(authorize?: false)
           |> Enum.map(& &1.account_login) == ["other-org"]
  end

  test "disconnecting the only installation shows the connect link again", %{
    conn: conn,
    user: user
  } do
    put_app_configured()
    installation = link_installation!(user, "acme-org")

    {:ok, view, _html} = live(conn, ~p"/profile/github")

    html =
      view
      |> element("button[phx-value-id='#{installation.id}']")
      |> render_click()

    assert html =~ "GitHub App disconnected"
    assert html =~ "Connect GitHub App"
    refute html =~ "acme-org"

    assert Installation
           |> Ash.Query.filter(user_id == ^user.id)
           |> Ash.read!(authorize?: false) == []
  end

  defp put_app_configured do
    Application.put_env(:camelot, :github_app,
      app_id: "123",
      slug: "camelot-dev",
      client_id: "Iv1.abc",
      client_secret: "secret",
      private_key: Base.encode64("not-a-real-key"),
      webhook_secret: "whsecret"
    )
  end

  defp link_installation!(user, account_login) do
    {:ok, installation} =
      Ash.create(
        Installation,
        %{
          installation_id: System.unique_integer([:positive]),
          account_login: account_login,
          account_type: :organization
        },
        authorize?: false
      )

    {:ok, linked} =
      Ash.update(installation, %{user_id: user.id}, action: :link_user, actor: user)

    linked
  end
end
