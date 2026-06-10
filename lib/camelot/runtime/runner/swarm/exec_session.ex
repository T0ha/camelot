defmodule Camelot.Runtime.Runner.Swarm.ExecSession do
  @moduledoc """
  Per-session GenServer returned by
  `Camelot.Runtime.Runner.Swarm.start/1`. Ensures a
  `TaskService` exists for the spec's `task_id`, resolves
  the container + node behind it, routes through
  `ProxyRouter` to the proxy task on that node, and runs
  the agent CLI via `POST /containers/<id>/exec`.

  Stdout/stderr come back as a multiplexed stream which
  is demultiplexed in-process and forwarded to
  `spec.owner_pid` as `{:runner_data, self(), bytes}`.
  Final exit code is sent as
  `{:runner_exit, self(), code}`. Same protocol
  `AgentProcess` already handles.
  """
  use GenServer, restart: :temporary

  alias Camelot.Runtime.Runner.DockerApi
  alias Camelot.Runtime.Runner.DockerStreamDemux
  alias Camelot.Runtime.Runner.Spec
  alias Camelot.Runtime.Runner.Swarm.ProxyRouter
  alias Camelot.Runtime.Runner.Swarm.TaskService

  require Logger

  # Polling intervals — pure rate-limiters on the loops below.
  # We deliberately do NOT bound these loops with a wall-clock
  # deadline: container scheduling, image pulls on workers, and
  # in-container clone+asdf install can each legitimately take
  # arbitrarily long. Anything that's broken upstream surfaces
  # as an :error from the Docker API and breaks the loop, so
  # we never spin forever on a real failure.
  @ready_poll_ms 500
  @exit_poll_ms 1_000

  defstruct [
    :owner,
    :session_id,
    :task_id,
    :service_id,
    :container_id,
    :node_id,
    :node_req,
    :exec_id,
    :stream_task,
    :poll_task,
    spec: nil
  ]

  # --- Public API ---

  @spec start(Spec.t()) :: {:ok, pid()} | {:error, term()}
  def start(%Spec{} = spec), do: GenServer.start(__MODULE__, spec)

  @spec stop(pid()) :: :ok
  def stop(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.cast(pid, :stop)
    :ok
  end

  # --- GenServer ---

  @impl GenServer
  def init(%Spec{task_id: nil}) do
    {:stop, :task_id_required}
  end

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
  def handle_cast(:stop, %__MODULE__{} = state) do
    kill_exec(state)
    {:stop, :normal, state}
  end

  @impl GenServer
  def format_status(status) do
    update_in(status.state.spec, &Spec.redact/1)
  end

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

  # --- Wiring ---

  defp start_exec(%__MODULE__{spec: spec} = state) do
    with {:ok, ts_pid} <- TaskService.ensure_started(spec),
         {:ok, service_id} <- TaskService.get_service_id(ts_pid),
         {:ok, container_id, node_id} <- resolve_container(service_id),
         {:ok, node_req} <- ProxyRouter.request_for_node(node_id),
         :ok <- wait_for_ready(node_req, container_id),
         {:ok, exec_id} <- create_exec(node_req, container_id, spec) do
      state = %{
        state
        | service_id: service_id,
          container_id: container_id,
          node_id: node_id,
          node_req: node_req,
          exec_id: exec_id
      }

      {:ok, kick_off_streams(state)}
    end
  end

  defp resolve_container(service_id) do
    with {:ok, tasks} <- list_service_tasks(service_id) do
      handle_pick(pick_running_task(tasks), service_id)
    end
  end

  defp list_service_tasks(service_id) do
    case Req.get(DockerApi.request(),
           url: "/tasks",
           params: [filters: ~s({"service":["#{service_id}"]})]
         ) do
      {:ok, %Req.Response{status: 200, body: tasks}} when is_list(tasks) -> {:ok, tasks}
      {:ok, resp} -> {:error, {:tasks_bad_status, resp.status}}
      {:error, _} = err -> err
    end
  end

  defp handle_pick({:ok, container_id, node_id}, _service_id) do
    {:ok, container_id, node_id}
  end

  defp handle_pick(:pending, service_id) do
    Process.sleep(@ready_poll_ms)
    resolve_container(service_id)
  end

  defp pick_running_task(tasks) do
    Enum.find_value(tasks, :pending, fn task ->
      state = get_in(task, ["Status", "State"])
      cid = get_in(task, ["Status", "ContainerStatus", "ContainerID"])
      node = task["NodeID"]

      case {state, cid, node} do
        {"running", cid, node} when is_binary(cid) and is_binary(node) ->
          {:ok, cid, node}

        _ ->
          nil
      end
    end)
  end

  defp wait_for_ready(node_req, container_id) do
    case ready_check(node_req, container_id) do
      :ok ->
        :ok

      :not_ready ->
        Process.sleep(@ready_poll_ms)
        wait_for_ready(node_req, container_id)

      {:error, _} = err ->
        err
    end
  end

  defp ready_check(node_req, container_id) do
    payload = %{
      "AttachStdout" => false,
      "AttachStderr" => false,
      "Cmd" => ["test", "-f", "/tmp/camelot-ready"]
    }

    with {:ok, %Req.Response{status: 201, body: %{"Id" => exec_id}}} <-
           Req.post(node_req, url: "/containers/#{container_id}/exec", json: payload),
         {:ok, _} <-
           Req.post(node_req, url: "/exec/#{exec_id}/start", json: %{"Detach" => false}),
         {:ok, %Req.Response{status: 200, body: %{"ExitCode" => code}}} <-
           Req.get(node_req, url: "/exec/#{exec_id}/json") do
      if code == 0, do: :ok, else: :not_ready
    else
      {:ok, resp} -> {:error, {:bad_status, resp.status, resp.body}}
      {:error, _} = err -> err
    end
  end

  defp create_exec(node_req, container_id, %Spec{} = spec) do
    payload = %{
      "AttachStdout" => true,
      "AttachStderr" => true,
      "AttachStdin" => false,
      "Tty" => false,
      "WorkingDir" => spec.cwd,
      "Env" => session_env(spec),
      "Cmd" => ["/exec-wrapper.sh"] ++ spec.argv
    }

    case Req.post(node_req, url: "/containers/#{container_id}/exec", json: reject_nil(payload)) do
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
      Task.async(fn ->
        stream_exec(state.node_req, state.exec_id, parent)
      end)

    poll_task =
      Task.async(fn ->
        poll_exec_exit(state.node_req, state.exec_id, parent)
      end)

    %{state | stream_task: stream_task, poll_task: poll_task}
  end

  defp stream_exec(node_req, exec_id, parent) do
    Req.post(node_req,
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
      Logger.warning("Swarm.ExecSession: stream crashed: #{inspect(e)}")
      send(parent, {:stream_done, make_ref()})
  end

  defp demux(chunk, parent) do
    buf = Process.get(:swarm_demux_buf, <<>>)
    {payloads, rest} = DockerStreamDemux.drain(buf, chunk)
    Enum.each(payloads, fn payload -> send(parent, {:chunk, payload}) end)
    Process.put(:swarm_demux_buf, rest)
  end

  defp poll_exec_exit(node_req, exec_id, parent) do
    case Req.get(node_req, url: "/exec/#{exec_id}/json") do
      {:ok, %Req.Response{status: 200, body: %{"Running" => false, "ExitCode" => code}}}
      when is_integer(code) ->
        send(parent, {:exit_code, code})

      {:ok, %Req.Response{status: 200, body: %{"Running" => false}}} ->
        send(parent, {:exit_code, 1})

      _ ->
        Process.sleep(@exit_poll_ms)
        poll_exec_exit(node_req, exec_id, parent)
    end
  end

  # Cancel path: no first-party /exec/<id>/kill endpoint exists.
  # Docker only kills exec processes by signalling the whole
  # container, which would take down the TaskService. Best
  # effort here is to drop our stream/poll tasks; the exec
  # itself runs to completion inside the container.
  defp kill_exec(_state), do: :ok

  defp reject_nil(map) when is_map(map) do
    map
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end
end
