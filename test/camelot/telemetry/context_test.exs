defmodule Camelot.Telemetry.ContextTest do
  use ExUnit.Case, async: false

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
end
