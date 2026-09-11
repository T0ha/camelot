defmodule CamelotWeb.AgentLiveTest do
  use CamelotWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "as a non-admin user" do
    setup :register_and_log_in_user

    test "redirects /agents to /", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/agents")
    end
  end

  describe "as an admin" do
    setup :register_and_log_in_admin

    test "loads /agents", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/agents")
      assert html =~ "Agent CLI"
    end

    test "lists the seeded agent CLIs with their max retries", %{conn: conn} do
      claude = agent!("claude_code")

      {:ok, _view, html} = live(conn, ~p"/agents")
      assert html =~ claude.slug
      assert html =~ to_string(claude.max_retries)
    end

    test "runner image picker suggests Camelot's built images and fills the field", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/agents/new")

      html =
        view
        |> element("#runner-image-picker-container button[phx-click=toggle_browser]")
        |> render_click()

      assert html =~ "ghcr.io/t0ha/camelot-runner-codex:latest"

      view
      |> element(~s(#runner-image-picker-container button[phx-value-image="ghcr.io/t0ha/camelot-runner-codex:latest"]))
      |> render_click()

      assert render(view) =~ ~s(value="ghcr.io/t0ha/camelot-runner-codex:latest")
    end
  end
end
