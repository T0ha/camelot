defmodule Camelot.Runtime.Runner.Swarm.ContainerFile do
  @moduledoc """
  One-shot file reads from a task's runner container.

  Resolves the Swarm service backing `task_id` (via the live
  `TaskService`, falling back to a Docker service lookup by
  name so reads survive an app restart), picks its running
  replica, and `cat`s the requested path through the node's
  `docker-socket-proxy` — the same short-exec pattern
  `ExecSession` uses to fetch the tee'd output file.

  The exec's exit code is checked so a missing file surfaces
  as `{:error, :read_failed}` instead of empty content.
  """

  alias Camelot.Runtime.Runner.DockerApi
  alias Camelot.Runtime.Runner.DockerStreamDemux
  alias Camelot.Runtime.Runner.Spec
  alias Camelot.Runtime.Runner.Swarm.ExecSession
  alias Camelot.Runtime.Runner.Swarm.ProxyRouter
  alias Camelot.Runtime.Runner.Swarm.TaskService

  # Agent home inside the runner image; `~` in agent-written
  # references expands to this.
  @container_home "/home/agent"

  @doc """
  Read `path` from the running container of the task's Swarm
  service. Leading `~` expands to the in-container agent home.
  """
  @spec read(String.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def read(task_id, path) when is_binary(task_id) and is_binary(path) do
    with {:ok, service_id} <- resolve_service_id(task_id),
         {:ok, container_id, node_id} <- resolve_container(service_id),
         {:ok, node_req} <- ProxyRouter.request_for_node(node_id) do
      exec_cat(node_req, container_id, expand_home(path))
    end
  end

  @doc """
  Expand a leading `~` to the in-container agent home.
  """
  @spec expand_home(String.t()) :: String.t()
  def expand_home("~/" <> rest), do: "#{@container_home}/#{rest}"
  def expand_home(path), do: path

  defp resolve_service_id(task_id) do
    case TaskService.lookup(task_id) do
      nil -> find_service_by_name(task_id)
      pid -> TaskService.get_service_id(pid)
    end
  end

  defp find_service_by_name(task_id) do
    name = Spec.task_runner_name(task_id)

    case Req.get(DockerApi.request(),
           url: "/services",
           params: [filters: ~s({"name":["#{name}"]})]
         ) do
      {:ok, %Req.Response{status: 200, body: [%{"ID" => id} | _]}} ->
        {:ok, id}

      {:ok, %Req.Response{status: 200, body: []}} ->
        {:error, :service_not_found}

      {:ok, resp} ->
        {:error, {:services_bad_status, resp.status}}

      {:error, _} = err ->
        err
    end
  end

  defp resolve_container(service_id) do
    case Req.get(DockerApi.request(),
           url: "/tasks",
           params: [filters: ~s({"service":["#{service_id}"]})]
         ) do
      {:ok, %Req.Response{status: 200, body: tasks}} when is_list(tasks) ->
        case ExecSession.pick_running_task(tasks) do
          {:ok, container_id, node_id} -> {:ok, container_id, node_id}
          :pending -> {:error, :no_running_container}
        end

      {:ok, resp} ->
        {:error, {:tasks_bad_status, resp.status}}

      {:error, _} = err ->
        err
    end
  end

  defp exec_cat(node_req, container_id, path) do
    payload = %{
      "AttachStdout" => true,
      "AttachStderr" => false,
      "Tty" => false,
      "Cmd" => ["cat", path]
    }

    with {:ok, %Req.Response{status: 201, body: %{"Id" => exec_id}}} <-
           Req.post(node_req, url: "/containers/#{container_id}/exec", json: payload),
         {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) <-
           Req.post(node_req,
             url: "/exec/#{exec_id}/start",
             json: %{"Detach" => false, "Tty" => false}
           ),
         {:ok, %Req.Response{status: 200, body: %{"ExitCode" => 0}}} <-
           Req.get(node_req, url: "/exec/#{exec_id}/json") do
      {payloads, _rest} = DockerStreamDemux.drain(<<>>, body)
      {:ok, IO.iodata_to_binary(payloads)}
    else
      {:error, _} = err -> err
      _ -> {:error, :read_failed}
    end
  end
end
