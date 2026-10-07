defmodule Camelot.Runtime.RunnerTest do
  # Mutates the global :runner app env, so it can't run async.
  use ExUnit.Case, async: false

  alias Camelot.Runtime.Runner
  alias Camelot.Runtime.Runner.DockerEngine
  alias Camelot.Runtime.Runner.LocalPort
  alias Camelot.Runtime.Runner.Swarm

  setup do
    original = Application.get_env(:camelot, :runner)
    on_exit(fn -> Application.put_env(:camelot, :runner, original) end)
    :ok
  end

  defp put_backend(backend) do
    runner = Application.get_env(:camelot, :runner, [])
    Application.put_env(:camelot, :runner, Keyword.put(runner, :backend, backend))
  end

  describe "cloud?/0" do
    test "is false for LocalPort" do
      put_backend(LocalPort)

      refute Runner.cloud?()
    end

    test "is true for DockerEngine" do
      put_backend(DockerEngine)

      assert Runner.cloud?()
    end

    test "is true for Swarm" do
      put_backend(Swarm)

      assert Runner.cloud?()
    end
  end
end
