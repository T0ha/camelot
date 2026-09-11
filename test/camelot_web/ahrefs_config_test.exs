defmodule CamelotWeb.AhrefsConfigTest do
  use CamelotWeb.ConnCase, async: false

  alias CamelotWeb.AhrefsConfig

  @snippet_src "https://analytics.ahrefs.com/analytics.js"

  setup do
    ahrefs = Application.get_env(:camelot, :ahrefs)

    on_exit(fn -> Application.put_env(:camelot, :ahrefs, ahrefs) end)

    :ok
  end

  defp put_key(key), do: Application.put_env(:camelot, :ahrefs, key: key)

  describe "key/0" do
    test "returns nil when no site key is configured" do
      put_key(nil)

      assert AhrefsConfig.key() == nil
    end

    test "returns the configured site key" do
      put_key("test-site-key")

      assert AhrefsConfig.key() == "test-site-key"
    end
  end

  describe "app layout" do
    test "omits the snippet when no site key is configured", %{conn: conn} do
      put_key(nil)

      refute conn |> get(~p"/sign-in") |> html_response(200) =~ @snippet_src
    end

    test "renders the snippet with the configured key", %{conn: conn} do
      put_key("test-site-key")

      body = conn |> get(~p"/sign-in") |> html_response(200)

      assert body =~ @snippet_src
      assert body =~ ~s(data-key="test-site-key")
    end
  end

  describe "docs layout" do
    setup %{conn: conn} do
      {:ok, conn: %{conn | host: "docs.localhost"}}
    end

    test "omits the snippet when no site key is configured", %{conn: conn} do
      put_key(nil)

      refute conn |> get("/") |> html_response(200) =~ @snippet_src
    end

    test "renders the snippet with the configured key", %{conn: conn} do
      put_key("test-site-key")

      body = conn |> get("/") |> html_response(200)

      assert body =~ @snippet_src
      assert body =~ ~s(data-key="test-site-key")
    end
  end
end
