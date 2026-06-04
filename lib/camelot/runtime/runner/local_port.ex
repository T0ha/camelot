defmodule Camelot.Runtime.Runner.LocalPort do
  @moduledoc """
  Runner backend that launches the agent CLI directly on
  the Camelot host via `Port.open`. Preserves the legacy
  behaviour for contributors who don't want to run
  Docker locally.

  Ignores the spec's `image`, `profile_volume`, and
  `secrets` fields — credentials in this mode are
  expected to live in the developer's own home
  directory.
  """
  @behaviour Camelot.Runtime.Runner

  use GenServer, restart: :temporary

  alias Camelot.Runtime.Runner
  alias Camelot.Runtime.Runner.Spec

  require Logger

  defstruct [:owner, :port, :session_id]

  @type state :: %__MODULE__{
          owner: pid(),
          port: port() | nil,
          session_id: String.t()
        }

  @impl Runner
  @spec start(Spec.t()) :: {:ok, pid()} | {:error, term()}
  def start(%Spec{} = spec) do
    GenServer.start(__MODULE__, spec)
  end

  @impl Runner
  @spec stop(pid()) :: :ok
  def stop(handle) when is_pid(handle) do
    if Process.alive?(handle), do: GenServer.cast(handle, :stop)
    :ok
  end

  # --- GenServer ---

  @impl GenServer
  def init(%Spec{owner_pid: owner, argv: argv, env: env, cwd: cwd, session_id: id}) do
    case open_port(argv, env, cwd) do
      {:ok, port} ->
        state = %__MODULE__{owner: owner, port: port, session_id: id}
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_cast(:stop, state) do
    close_port(state)
    {:stop, :normal, %{state | port: nil}}
  end

  @impl GenServer
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    send(state.owner, {:runner_data, self(), to_string(data)})
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    send(state.owner, {:runner_exit, self(), code})
    {:stop, :normal, %{state | port: nil}}
  end

  def handle_info({:EXIT, port, _reason}, %{port: port} = state) do
    send(state.owner, {:runner_exit, self(), 1})
    {:stop, :normal, %{state | port: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Internals ---

  defp open_port([cli | rest], env, cwd) do
    with sh when is_binary(sh) <- System.find_executable("sh"),
         resolved when is_binary(resolved) <- resolve_cli(cli) do
      port =
        Port.open(
          {:spawn_executable, sh},
          [
            :binary,
            :exit_status,
            :use_stdio,
            :stderr_to_stdout
          ] ++ cwd_opt(cwd) ++ [env: env_for_port(env), args: shell_args(resolved, rest)]
        )

      {:ok, port}
    else
      _ -> {:error, :cli_not_found}
    end
  rescue
    e ->
      Logger.error("LocalPort failed to open port: #{inspect(e)}")
      {:error, e}
  end

  defp resolve_cli(cli) do
    cond do
      File.exists?(cli) -> cli
      bin = System.find_executable(cli) -> bin
      true -> nil
    end
  end

  defp cwd_opt(nil), do: []
  defp cwd_opt(path), do: [cd: to_charlist(path)]

  defp shell_args(cli, rest) do
    ["-c", ~s(exec "$@" </dev/null), "--", cli | rest]
  end

  defp env_for_port(env) do
    Enum.map(env, fn {k, v} ->
      {to_charlist(k), to_charlist(v)}
    end)
  end

  defp close_port(%{port: nil}), do: :ok

  defp close_port(%{port: port}) do
    Port.close(port)
  catch
    :error, :badarg -> :ok
  end
end
