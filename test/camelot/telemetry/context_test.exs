defmodule Camelot.Telemetry.ContextTest do
  use ExUnit.Case, async: false

  alias Camelot.Telemetry.Capture
  alias Camelot.Telemetry.Context

  setup do
    previous = Application.get_env(:camelot, :telemetry)
    on_exit(fn -> Application.put_env(:camelot, :telemetry, previous) end)

    %{previous: previous}
  end

  defp put_environment(environment, ctx) do
    Application.put_env(:camelot, :telemetry, Keyword.put(ctx.previous, :environment, environment))
  end

  test "environment comes from application config", ctx do
    put_environment("production", ctx)

    assert Context.environment() == "production"
    assert Context.production?()
  end

  test "global properties carry the environment on every capture", ctx do
    put_environment("test", ctx)

    assert Context.global_properties() == %{environment: "test"}
  end

  test "everything outside production counts as internal", ctx do
    put_environment("test", ctx)

    assert Context.internal?("someone@rollhub.com")
    assert Context.internal?(nil)
  end

  test "in production only the maintainer's email is internal", ctx do
    put_environment("production", ctx)

    assert Context.internal?("t0hashvein@gmail.com")
    assert Context.internal?("t0hashvein+camelot@gmail.com")
    assert Context.internal?(%{email: "T0hashvein@Gmail.com"})
  end

  test "a client domain is not internal in production", ctx do
    put_environment("production", ctx)

    refute Context.internal?("someone@rollhub.com")
    refute Context.internal?(%{email: Ash.CiString.new("someone@rollhub.com")})
    refute Context.internal?(nil)
  end

  # Both clusters run the same MIX_ENV=prod release, so nothing in the
  # application can tell them apart: DEPLOYMENT_ENV is the only signal,
  # and its unset default has to be the collector's, or a PostHog
  # capture and the collector's own data for the same box disagree
  # about which cluster produced them.
  describe "the DEPLOYMENT_ENV default" do
    @gateway_config "otel-collector/gateway.yaml"
    @runtime_config "config/runtime.exs"

    test "matches the otel collector gateway's" do
      [_match, gateway_default] =
        Regex.run(~r/DEPLOYMENT_ENV:-(\w+)/, File.read!(@gateway_config))

      assert File.read!(@runtime_config) =~ ~s({nil, :prod} -> "#{gateway_default}"),
             "config/runtime.exs must default DEPLOYMENT_ENV to " <>
               "#{inspect(gateway_default)} in a release, as #{@gateway_config} does"
    end

    test "falls back to the Mix environment outside a release" do
      assert Context.environment() == "test"
      refute Context.production?()
    end
  end

  # `environment` does not reach the wire through anything this module
  # merges. The library merges the PostHog instance's configured
  # `global_properties` *last* (`deps/posthog/lib/posthog.ex`), after
  # the caller's own, so the `config :posthog, global_properties:`
  # block in `config/runtime.exs` is the only thing deciding whether
  # the acceptance criterion's `environment = production` filter
  # matches anything at all.
  #
  # That block is introduced there for backend `$exception`s and
  # documented as such, so it reads as error-tracking-only: removing
  # it would silently take `environment` off every product event too,
  # with nothing failing. These two tests are what fails instead.
  describe "the PostHog instance's global properties" do
    test "carry what this module defines" do
      configured = PostHog.Registry.config(PostHog).global_properties

      for {key, value} <- Context.global_properties() do
        assert configured[key] == value,
               "config :posthog, global_properties: must carry " <>
                 "#{inspect(key)} => #{inspect(value)}, the value " <>
                 "Camelot.Telemetry.Context defines"
      end
    end

    test "reach a capture, and a caller cannot forge one" do
      Capture.capture("global_properties_probe", "person-1", %{environment: "forged"})

      assert [event] = Enum.filter(PostHog.Test.all_captured(), &(&1.event == "global_properties_probe"))

      assert event.properties[:environment] == Context.environment()
    end
  end
end
