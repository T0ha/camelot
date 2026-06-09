defmodule Camelot.Runtime.Runner.DockerEngine.ExecSession do
  @moduledoc """
  Per-session GenServer returned by
  `Camelot.Runtime.Runner.DockerEngine.start/1`.

  Ensures a `TaskContainer` exists for the spec's
  `task_id` and runs the agent CLI via
  `POST /containers/<id>/exec`. Streams the multiplexed
  stdout/stderr back to `spec.owner_pid` using the same
  message protocol as the Swarm backend.
  """
  use GenServer, restart: :temporary

  alias Camelot.Runtime.Runner.DockerApi
  alias Camelot.Runtime.Runner.DockerEngine.TaskContainer
  alias Camelot.Runtime.Runner.DockerStreamDemux
  alias Camelot.Runtime.Runner.Spec

  require Logger

  @ready_poll_ms 500
  @ready_timeout_ms 60_000
  @exit_poll_ms 1_000

  defstruct [
    :owner,
    :session_id,
    :task_id,
    :container_id,
    :exec_id,
    :stream_task,
    :poll_task,
    spec: nil
  ]

  @spec start(Spec.t()) :: {:ok, pid()} | {:error, term()}
  def start(%Spec{} = spec), do: GenServer.start(__MODULE__, spec)

  @spec stop(pid()) :: :ok
  def stop(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.cast(pid, :stop)
    :ok
  end

  @impl GenServer
  def init(%Spec{task_id: nil}), do: {:stop, :task_id_required}

  def init(%Spec{} = spec) do
    state = %__MODULE__{
      owner: spec.owner_pid,
      session_id: spec.session_id,
      task_id: spec.task_id,
      spec: spec
    }

    {:ok, state, {:continue, :start_exec}}
  end

  @impl GenServer
  def handle_continue(:start_exec, state) do
    case start_exec(state) do
      {:ok, state} -> {:noreply, state}
      {:error, reason} -> {:stop, reason, state}
    end
  end

  @impl GenServer
  def handle_cast(:stop, state), do: {:stop, :normal, state}

  @impl GenServer
  def handle_info({:chunk, bytes}, %__MODULE__{} = state) do
    send(state.owner, {:runner_data, self(), bytes})
    {:noreply, state}
  end

  def handle_info({:stream_done, _}, state), do: {:noreply, state}

  def handle_info({:exit_code, code}, %__MODULE__{} = state) do
    send(state.owner, {:runner_exit, self(), code})
    {:stop, :normal, state}
  end

  def handle_info({ref, _}, state) when is_reference(ref), do: {:noreply, state}
  def handle_info({:DOWN, _, _, _, _}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  defp start_exec(%__MODULE__{spec: spec} = state) do
    with {:ok, tc_pid} <- TaskContainer.ensure_started(spec),
         {:ok, container_id} <- TaskContainer.get_container_id(tc_pid),
         :ok <- wait_for_ready(container_id),
         {:ok, exec_id} <- create_exec(container_id, spec) do
      state = %{state | container_id: container_id, exec_id: exec_id}
      {:ok, kick_off_streams(state)}
    end
  end

  defp wait_for_ready(container_id) do
    deadline = System.monotonic_time(:millisecond) + @ready_timeout_ms
    do_wait_for_ready(container_id, deadline)
  end

  defp do_wait_for_ready(container_id, deadline) do
    case ready_check(container_id) do
      :ok ->
        :ok

      :not_ready ->
        if System.monotonic_time(:millisecond) > deadline do
          {:error, :ready_timeout}
        else
          Process.sleep(@ready_poll_ms)
          do_wait_for_ready(container_id, deadline)
        end

      {:error, _} = err ->
        err
    end
  end

  defp ready_check(container_id) do
    payload = %{
      "AttachStdout" => false,
      "AttachStderr" => false,
      "Cmd" => ["test", "-f", "/run/camelot-ready"]
    }

    with {:ok, %Req.Response{status: 201, body: %{"Id" => exec_id}}} <-
           Req.post(DockerApi.request(), url: "/containers/#{container_id}/exec", json: payload),
         {:ok, _} <-
           Req.post(DockerApi.request(),
             url: "/exec/#{exec_id}/start",
             json: %{"Detach" => false}
           ),
         {:ok, %Req.Response{status: 200, body: %{"ExitCode" => code}}} <-
           Req.get(DockerApi.request(), url: "/exec/#{exec_id}/json") do
      if code == 0, do: :ok, else: :not_ready
    else
      {:ok, resp} -> {:error, {:bad_status, resp.status, resp.body}}
      {:error, _} = err -> err
    end
  end

  defp create_exec(container_id, %Spec{} = spec) do
    payload = %{
      "AttachStdout" => true,
      "AttachStderr" => true,
      "AttachStdin" => false,
      "Tty" => false,
      "WorkingDir" => spec.cwd,
      "Env" => session_env(spec),
      "Cmd" => ["/exec-wrapper.sh"] ++ spec.argv
    }

    case Req.post(DockerApi.request(),
           url: "/containers/#{container_id}/exec",
           json: reject_nil(payload)
         ) do
      {:ok, %Req.Response{status: 201, body: %{"Id" => exec_id}}} ->
        {:ok, exec_id}

      {:ok, resp} ->
        {:error, {:exec_create_failed, resp.status, resp.body}}

      {:error, _} = err ->
        err
    end
  end

  defp session_env(%Spec{mcp_config_json: nil}), do: nil

  defp session_env(%Spec{mcp_config_json: json}) do
    ["PROJECT_MCP_CONFIG_JSON=#{json}"]
  end

  defp kick_off_streams(%__MODULE__{} = state) do
    parent = self()

    stream_task =
      Task.async(fn -> stream_exec(state.exec_id, parent) end)

    poll_task =
      Task.async(fn -> poll_exec_exit(state.exec_id, parent) end)

    %{state | stream_task: stream_task, poll_task: poll_task}
  end

  defp stream_exec(exec_id, parent) do
    Req.post(DockerApi.request(),
      url: "/exec/#{exec_id}/start",
      json: %{"Detach" => false, "Tty" => false},
      receive_timeout: :infinity,
      into: fn {:data, chunk}, {req, resp} ->
        demux(chunk, parent)
        {:cont, {req, resp}}
      end
    )

    send(parent, {:stream_done, make_ref()})
  rescue
    e ->
      Logger.warning("DockerEngine.ExecSession stream crashed: #{inspect(e)}")
      send(parent, {:stream_done, make_ref()})
  end

  defp demux(chunk, parent) do
    buf = Process.get(:de_demux_buf, <<>>)
    {payloads, rest} = DockerStreamDemux.drain(buf, chunk)
    Enum.each(payloads, fn payload -> send(parent, {:chunk, payload}) end)
    Process.put(:de_demux_buf, rest)
  end

  defp poll_exec_exit(exec_id, parent) do
    case Req.get(DockerApi.request(), url: "/exec/#{exec_id}/json") do
      {:ok, %Req.Response{status: 200, body: %{"Running" => false, "ExitCode" => code}}}
      when is_integer(code) ->
        send(parent, {:exit_code, code})

      {:ok, %Req.Response{status: 200, body: %{"Running" => false}}} ->
        send(parent, {:exit_code, 1})

      _ ->
        Process.sleep(@exit_poll_ms)
        poll_exec_exit(exec_id, parent)
    end
  end

  defp reject_nil(map) when is_map(map) do
    map
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end
end
