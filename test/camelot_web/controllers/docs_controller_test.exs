defmodule CamelotWeb.DocsControllerTest do
  use CamelotWeb.ConnCase, async: true

  # Requests to the public docs site come in on the `docs.` host.
  setup %{conn: conn} do
    {:ok, conn: %{conn | host: "docs.localhost"}}
  end

  describe "GET / (index)" do
    test "renders the category tree of published pages", %{conn: conn} do
      conn = get(conn, "/")
      body = html_response(conn, 200)

      assert body =~ "Self Hosting"
      assert body =~ "GitHub App"
      assert body =~ "Cloud"
      # internal (unpublished) docs never appear
      refute body =~ "Session adoption"
    end

    test "is cacheable: sets cache-control and sets no cookie", %{conn: conn} do
      conn = get(conn, "/")

      assert ["public, max-age=0, s-maxage=" <> _] =
               get_resp_header(conn, "cache-control")

      assert get_resp_header(conn, "set-cookie") == []
    end
  end

  describe "GET /*path (show)" do
    test "renders a page addressed by a multi-segment slug", %{conn: conn} do
      conn = get(conn, "/self-hosting/cluster-runners")
      body = html_response(conn, 200)

      assert body =~ "Cluster runners"
      # rendered markdown, not raw
      assert body =~ "<h1>"
    end

    test "returns 404 for an unknown slug", %{conn: conn} do
      conn = get(conn, "/self-hosting/does-not-exist")
      assert response(conn, 404)
    end

    test "renders the cloud get-started page", %{conn: conn} do
      conn = get(conn, "/cloud/get-started")
      body = html_response(conn, 200)

      assert body =~ "Get Started"
      assert body =~ "<h1>"
    end
  end
end
