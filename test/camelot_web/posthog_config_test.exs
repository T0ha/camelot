defmodule CamelotWeb.PostHogConfigTest do
  use ExUnit.Case, async: false

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
               email: nil
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
               email: nil
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
                 email: "a@example.com"
               }
    end
  end
end
