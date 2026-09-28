defmodule CamelotWeb.PostHogConfigTest do
  use ExUnit.Case, async: false

  alias Camelot.Telemetry.Context
  alias CamelotWeb.PostHogConfig

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

  describe "enabled?/0" do
    test "reflects the :posthog, :enable application env" do
      Application.put_env(:posthog, :enable, false)
      refute PostHogConfig.enabled?()

      Application.put_env(:posthog, :enable, true)
      assert PostHogConfig.enabled?()
    end
  end

  describe "for/1" do
    test "returns nil when disabled" do
      Application.put_env(:posthog, :enable, false)

      assert PostHogConfig.for(%{current_user: %{id: "u1", email: "a@example.com"}}) == nil
    end

    test "returns nil distinct_id/email when there is no current user" do
      Application.put_env(:posthog, :enable, true)
      Application.put_env(:posthog, :api_key, "phc_test")
      Application.put_env(:posthog, :api_host, "https://us.i.posthog.com")

      assert PostHogConfig.for(%{}) == %{
               api_key: "phc_test",
               api_host: "https://us.i.posthog.com",
               distinct_id: nil,
               email: nil,
               environment: Context.environment(),
               is_internal: to_string(Context.internal?(nil))
             }
    end

    test "returns nil distinct_id/email when current_user is nil" do
      Application.put_env(:posthog, :enable, true)
      Application.put_env(:posthog, :api_key, "phc_test")
      Application.put_env(:posthog, :api_host, "https://us.i.posthog.com")

      assert PostHogConfig.for(%{current_user: nil}) == %{
               api_key: "phc_test",
               api_host: "https://us.i.posthog.com",
               distinct_id: nil,
               email: nil,
               environment: Context.environment(),
               is_internal: to_string(Context.internal?(nil))
             }
    end

    test "returns distinct_id/email when a current user is present" do
      Application.put_env(:posthog, :enable, true)
      Application.put_env(:posthog, :api_key, "phc_test")
      Application.put_env(:posthog, :api_host, "https://us.i.posthog.com")

      assert PostHogConfig.for(%{current_user: %{id: "user-123", email: "a@example.com"}}) ==
               %{
                 api_key: "phc_test",
                 api_host: "https://us.i.posthog.com",
                 distinct_id: "user-123",
                 email: "a@example.com",
                 environment: Context.environment(),
                 is_internal: to_string(Context.internal?(%{email: "a@example.com"}))
               }
    end
  end

  describe "environment and internal traffic" do
    setup do
      previous = Application.get_env(:camelot, :telemetry)
      Application.put_env(:posthog, :enable, true)
      Application.put_env(:posthog, :api_key, "phc_test")

      on_exit(fn -> Application.put_env(:camelot, :telemetry, previous) end)

      %{previous: previous}
    end

    defp put_environment(environment, ctx) do
      Application.put_env(
        :camelot,
        :telemetry,
        Keyword.put(ctx.previous, :environment, environment)
      )
    end

    test "the browser gets the same environment the server captures carry", ctx do
      put_environment("production", ctx)

      assert %{environment: "production"} =
               PostHogConfig.for(%{current_user: %{id: "u1", email: "a@example.com"}})
    end

    # The two clusters share one PostHog project, so staging traffic
    # has to be excludable without excluding a real customer.
    test "the maintainer is internal in production, a client is not", ctx do
      put_environment("production", ctx)

      assert %{is_internal: "true"} =
               PostHogConfig.for(%{current_user: %{id: "u1", email: "t0hashvein@gmail.com"}})

      assert %{is_internal: "false"} =
               PostHogConfig.for(%{current_user: %{id: "u2", email: "someone@rollhub.com"}})
    end

    test "everything on the test cluster is internal", ctx do
      put_environment("test", ctx)

      assert %{environment: "test", is_internal: "true"} =
               PostHogConfig.for(%{current_user: %{id: "u2", email: "someone@rollhub.com"}})
    end
  end
end
