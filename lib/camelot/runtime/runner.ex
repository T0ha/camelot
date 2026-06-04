defmodule Camelot.Runtime.Runner do
  @moduledoc """
  Behaviour every runner backend implements.

  A runner takes a `Runner.Spec` describing one CLI
  invocation (image, argv, env, mounts, secrets, etc.)
  and launches it. It returns a handle whose owning
  process forwards stdout/stderr to the caller as
  `{:runner_data, handle, bytes}` and the final exit as
  `{:runner_exit, handle, exit_code}` — the same message
  shape Port produces, so `AgentProcess` can route both
  alike.

  Three implementations:

    * `Camelot.Runtime.Runner.LocalPort` — wraps the
      legacy `Port.open` flow. Default in dev/test.
    * `Camelot.Runtime.Runner.DockerEngine` — talks to a
      local Docker daemon via the HTTP API. Useful for
      single-node setups or for testing the
      containerised path on a dev box.
    * `Camelot.Runtime.Runner.Swarm` — talks to a Swarm
      manager and creates one-shot services. Default in
      prod.
  """

  alias Camelot.Runtime.Runner.Spec

  @type handle :: pid()
  @type reason :: term()

  @callback start(Spec.t()) :: {:ok, handle()} | {:error, reason()}
  @callback stop(handle()) :: :ok

  @doc """
  Returns the configured runner backend module.
  """
  @spec backend() :: module()
  def backend do
    :camelot
    |> Application.fetch_env!(:runner)
    |> Keyword.fetch!(:backend)
  end

  @doc """
  Start a runner using the configured backend.
  """
  @spec start(Spec.t()) :: {:ok, handle()} | {:error, reason()}
  def start(%Spec{} = spec), do: backend().start(spec)

  @doc """
  Stop a runner using the configured backend.
  """
  @spec stop(handle()) :: :ok
  def stop(handle), do: backend().stop(handle)
end
