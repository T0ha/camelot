defmodule Camelot.Runtime.Runner.DockerEngine.ContainerFile do
  @moduledoc """
  One-shot file reads from a task's runner container on the
  local Docker daemon.

  Resolves the container backing `task_id` (via the live
  `TaskContainer`, falling back to a Docker lookup by name so
  reads survive an app restart) and `cat`s the requested path
  — the same short-exec pattern `ExecSession` uses to fetch
  the tee'd output file. The exec's exit code is checked so a
  missing file surfaces as `{:error, :read_failed}` instead
  of empty content.
  """

  alias Camelot.Runtime.Runner.DockerApi
  alias Camelot.Runtime.Runner.DockerEngine.TaskContainer
  alias Camelot.Runtime.Runner.DockerStreamDemux
  alias Camelot.Runtime.Runner.Spec

  # Agent home inside the runner image; `~` in agent-written
  # references expands to this.
  @container_home "/home/agent"

  @doc """
  Read `path` from the task's running container. Leading `~`
  expands to the in-container agent home.
  """
  @spec read(String.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def read(task_id, path) when is_binary(task_id) and is_binary(path) do
    case resolve_container_id(task_id) do
      {:ok, container_id} ->
        exec_cat(container_id, expand_home(path))

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Expand a leading `~` to the in-container agent home.
  """
  @spec expand_home(String.t()) :: String.t()
  def expand_home("~/" <> rest), do: "#{@container_home}/#{rest}"
  def expand_home(path), do: path

  defp resolve_container_id(task_id) do
    case TaskContainer.lookup(task_id) do
      nil -> find_container_by_name(task_id)
      pid -> TaskContainer.get_container_id(pid)
    end
  end

  defp find_container_by_name(task_id) do
    name = Spec.task_runner_name(task_id)

    case Req.get(DockerApi.request(),
           url: "/containers/json",
           params: [filters: ~s({"name":["#{name}"]})]
         ) do
      {:ok, %Req.Response{status: 200, body: [%{"Id" => id} | _]}} ->
        {:ok, id}

      {:ok, %Req.Response{status: 200, body: []}} ->
        {:error, :container_not_found}

      {:ok, resp} ->
        {:error, {:containers_bad_status, resp.status}}

      {:error, _} = err ->
        err
    end
  end

  defp exec_cat(container_id, path) do
    payload = %{
      "AttachStdout" => true,
      "AttachStderr" => false,
      "Tty" => false,
      "Cmd" => ["cat", path]
    }

    with {:ok, %Req.Response{status: 201, body: %{"Id" => exec_id}}} <-
           Req.post(DockerApi.request(),
             url: "/containers/#{container_id}/exec",
             json: payload
           ),
         {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) <-
           Req.post(DockerApi.request(),
             url: "/exec/#{exec_id}/start",
             json: %{"Detach" => false, "Tty" => false}
           ),
         {:ok, %Req.Response{status: 200, body: %{"ExitCode" => 0}}} <-
           Req.get(DockerApi.request(), url: "/exec/#{exec_id}/json") do
      {payloads, _rest} = DockerStreamDemux.drain(<<>>, body)
      {:ok, IO.iodata_to_binary(payloads)}
    else
      {:error, _} = err -> err
      _ -> {:error, :read_failed}
    end
  end
end
