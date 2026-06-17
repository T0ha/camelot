defmodule CamelotWeb.AgentTemplateLiveTest do
  use CamelotWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "as a non-admin user" do
    setup :register_and_log_in_user

    test "redirects /agent-templates to /", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/agent-templates")
    end
  end

  describe "as an admin" do
    setup :register_and_log_in_admin

    test "loads /agent-templates", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/agent-templates")
      assert html =~ "Templates" or html =~ "templates"
    end
  end
end
