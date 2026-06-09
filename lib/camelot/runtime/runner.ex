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
  Tear down the long-lived per-task container/service for
  `task_id`. Called by `AgentProcess` when the task hits a
  terminal stage (`:done` or `:cancelled`). Backends that
  don't keep state across sessions (`LocalPort`) return `:ok`
  immediately.
  """
  @callback stop_task(task_id :: String.t()) :: :ok

  @optional_callbacks stop_task: 1

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

  @doc """
  Tear down the per-task runner for `task_id` via the
  configured backend. Backends that don't implement
  `stop_task/1` are treated as a no-op.
  """
  @spec stop_task(String.t()) :: :ok
  def stop_task(task_id) do
    mod = backend()

    if function_exported?(mod, :stop_task, 1) do
      mod.stop_task(task_id)
    else
      :ok
    end
  end
end
