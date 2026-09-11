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

    test "renders Sign In and Sign Up links to the main host", %{conn: conn} do
      body = conn |> get("/") |> html_response(200)
      sign_in_href = ~s(href="#{CamelotWeb.Endpoint.url()}/sign-in")

      assert body =~ sign_in_href
      assert body =~ "Sign In"
      assert body =~ "Sign Up"
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
      assert body =~ ~s(href="#{CamelotWeb.Endpoint.url()}/sign-in")
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

  describe "PostHog" do
    setup do
      enable = Application.get_env(:posthog, :enable)
      api_key = Application.get_env(:posthog, :api_key)
      api_host = Application.get_env(:posthog, :api_host)

      on_exit(fn ->
        Application.put_env(:posthog, :enable, enable)
        Application.put_env(:posthog, :api_key, api_key)
        Application.put_env(:posthog, :api_host, api_host)
      end)

      :ok
    end

    test "index includes the posthog config and docs.js script when enabled", %{conn: conn} do
      Application.put_env(:posthog, :enable, true)
      Application.put_env(:posthog, :api_key, "phc_test")
      Application.put_env(:posthog, :api_host, "https://us.i.posthog.com")

      body = conn |> get("/") |> html_response(200)

      assert body =~ ~s(id="posthog-config")
      assert body =~ "/assets/js/docs.js"
    end

    test "show includes the posthog config and docs.js script when enabled", %{conn: conn} do
      Application.put_env(:posthog, :enable, true)
      Application.put_env(:posthog, :api_key, "phc_test")
      Application.put_env(:posthog, :api_host, "https://us.i.posthog.com")

      body = conn |> get("/self-hosting/cluster-runners") |> html_response(200)

      assert body =~ ~s(id="posthog-config")
      assert body =~ "/assets/js/docs.js"
    end

    test "index omits the posthog config when disabled", %{conn: conn} do
      Application.put_env(:posthog, :enable, false)

      body = conn |> get("/") |> html_response(200)

      refute body =~ ~s(id="posthog-config")
    end

    test "still sets no cookie and a cache-control header when enabled", %{conn: conn} do
      Application.put_env(:posthog, :enable, true)
      Application.put_env(:posthog, :api_key, "phc_test")
      Application.put_env(:posthog, :api_host, "https://us.i.posthog.com")

      conn = get(conn, "/")

      assert ["public, max-age=0, s-maxage=" <> _] =
               get_resp_header(conn, "cache-control")

      assert get_resp_header(conn, "set-cookie") == []
    end
  end
end
