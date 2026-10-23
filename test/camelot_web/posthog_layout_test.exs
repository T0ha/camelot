defmodule CamelotWeb.PostHogLayoutTest do
  # Both root layouts hand the browser the same `#posthog-config` meta
  # tag. `environment` and `is_internal` on it become super-properties
  # on every browser capture, `$exception` included — without them a
  # docs-site error carries `environment: undefined` and cannot be
  # told apart between the two clusters.
  use CamelotWeb.ConnCase, async: false

  alias Camelot.Telemetry.Context

  setup do
    enable = Application.get_env(:posthog, :enable)
    api_key = Application.get_env(:posthog, :api_key)
    api_host = Application.get_env(:posthog, :api_host)

    Application.put_env(:posthog, :enable, true)
    Application.put_env(:posthog, :api_key, "phc_test")
    Application.put_env(:posthog, :api_host, "https://us.i.posthog.com")

    on_exit(fn ->
      Application.put_env(:posthog, :enable, enable)
      Application.put_env(:posthog, :api_key, api_key)
      Application.put_env(:posthog, :api_host, api_host)
    end)

    :ok
  end

  defp posthog_config(body) do
    body
    |> LazyHTML.from_document()
    |> LazyHTML.query("meta#posthog-config")
  end

  defp attribute(meta, name) do
    case LazyHTML.attribute(meta, name) do
      [value] -> value
      [] -> nil
    end
  end

  describe "app layout" do
    test "carries the key, host, environment and internal flag", %{conn: conn} do
      meta = conn |> get(~p"/sign-in") |> html_response(200) |> posthog_config()

      assert attribute(meta, "data-api-key") == "phc_test"
      assert attribute(meta, "data-api-host") == "https://us.i.posthog.com"
      assert attribute(meta, "data-environment") == Context.environment()

      assert attribute(meta, "data-is-internal") ==
               to_string(Context.internal?(nil))

      assert attribute(meta, "data-distinct-id") == nil
    end

    test "identifies the signed-in user", %{conn: conn} do
      %{conn: conn, user: user} = register_and_log_in_user(%{conn: conn})

      meta = conn |> get(~p"/projects") |> html_response(200) |> posthog_config()

      assert attribute(meta, "data-distinct-id") == user.id
      assert attribute(meta, "data-email") == to_string(user.email)
    end

    test "is omitted when PostHog is disabled", %{conn: conn} do
      Application.put_env(:posthog, :enable, false)

      body = conn |> get(~p"/sign-in") |> html_response(200)

      assert body |> posthog_config() |> Enum.empty?()
    end
  end

  describe "docs layout" do
    setup %{conn: conn} do
      {:ok, conn: %{conn | host: "docs.localhost"}}
    end

    test "carries the environment and internal flag too", %{conn: conn} do
      meta = conn |> get("/") |> html_response(200) |> posthog_config()

      assert attribute(meta, "data-api-key") == "phc_test"
      assert attribute(meta, "data-environment") == Context.environment()

      assert attribute(meta, "data-is-internal") ==
               to_string(Context.internal?(nil))
    end
  end
end
