defmodule Camelot.Runtime.SessionRegistry do
  @moduledoc """
  Registry mapping `session_id` → owning `AgentProcess`
  pid. Lets the Reconciler tell genuinely abandoned
  sessions apart from ones that are still running with a
  live BEAM process behind them.

  AgentProcess registers itself on the `:runner_slot`
  transition and unregisters on session exit (success,
  failure, cancel, or process termination — the Registry
  auto-removes entries when the owning pid dies).
  """

  @name __MODULE__

  @spec child_spec(any()) :: Supervisor.child_spec()
  def child_spec(_),
    do: Registry.child_spec(keys: :unique, name: @name)

  @doc """
  Registers the calling process as owner of `session_id`.
  Returns `{:ok, _}` or `{:error, {:already_registered, pid}}`.
  """
  @spec register(String.t()) :: {:ok, pid()} | {:error, term()}
  def register(session_id) do
    Registry.register(@name, session_id, nil)
  end

  @doc """
  Unregisters the calling process as owner of `session_id`.
  Safe to call even if no entry exists.
  """
  @spec unregister(String.t()) :: :ok
  def unregister(session_id) do
    Registry.unregister(@name, session_id)
  end

  @doc """
  Returns the pid that owns `session_id`, or `nil` if no
  live process claims it.
  """
  @spec lookup(String.t()) :: pid() | nil
  def lookup(session_id) do
    case Registry.lookup(@name, session_id) do
      [{pid, _}] -> pid
      _ -> nil
    end
  end
end
