defmodule Camelot.Runtime.Runner.DockerEngine.TaskContainer do
  @moduledoc """
  Long-lived GenServer that owns the Docker Engine
  container backing one Task. Mirrors
  `Camelot.Runtime.Runner.Swarm.TaskService` but for the
  single-host backend.

  Sessions of that Task `docker exec` into the container.
  Registered under `Camelot.Runtime.Runner.DockerEngine.TaskRegistry`
  keyed by `task_id`.
  """
  use GenServer, restart: :temporary

  alias Camelot.Board.Task
  alias Camelot.Runtime.Runner.DockerApi
  alias Camelot.Runtime.Runner.Spec

  require Logger

  defstruct [:task_id, :container_id, :spec]

  @type state :: %__MODULE__{
          task_id: String.t(),
          container_id: String.t() | nil,
          spec: Spec.t() | nil
        }

  # --- Public API ---

  @spec ensure_started(Spec.t()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(%Spec{task_id: task_id} = spec) when is_binary(task_id) do
    case Registry.lookup(registry(), task_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(supervisor(), {__MODULE__, spec}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, _} = err -> err
        end
    end
  end

  @spec lookup(String.t()) :: pid() | nil
  def lookup(task_id) do
    case Registry.lookup(registry(), task_id) do
      [{pid, _}] -> pid
      _ -> nil
    end
  end

  @spec get_container_id(pid()) :: {:ok, String.t()} | {:error, term()}
  def get_container_id(pid) do
    GenServer.call(pid, :get_container_id, 60_000)
  end

  @spec stop_task(String.t()) :: :ok
  def stop_task(task_id) do
    case lookup(task_id) do
      nil -> :ok
      pid -> GenServer.cast(pid, :stop_task)
    end

    :ok
  end

  @doc false
  def start_link(%Spec{task_id: task_id} = spec) when is_binary(task_id) do
    GenServer.start_link(__MODULE__, spec, name: via(task_id))
  end

  defp via(task_id), do: {:via, Registry, {registry(), task_id}}

  defp registry, do: Camelot.Runtime.Runner.DockerEngine.TaskRegistry

  defp supervisor, do: Camelot.Runtime.Runner.DockerEngine.TaskSupervisor

  # --- GenServer ---

  @impl GenServer
  def init(%Spec{} = spec) do
    state = %__MODULE__{task_id: spec.task_id, spec: spec}
    {:ok, state, {:continue, :ensure_container}}
  end

  @impl GenServer
  def handle_continue(:ensure_container, %__MODULE__{} = state) do
    case ensure_container(state) do
      {:ok, container_id} ->
        {:noreply, %{state | container_id: container_id}}

      {:error, reason} ->
        Logger.error("DockerEngine.TaskContainer #{state.task_id}: ensure failed: #{inspect(reason)}")

        {:stop, reason, state}
    end
  end

  @impl GenServer
  def handle_call(:get_container_id, _from, %__MODULE__{container_id: id} = state) when is_binary(id) do
    if container_alive?(id) do
      {:reply, {:ok, id}, state}
    else
      Logger.info("DockerEngine.TaskContainer #{state.task_id}: cached container #{id} is gone; recreating")

      case create_and_persist(state.task_id, state.spec) do
        {:ok, new_id} -> {:reply, {:ok, new_id}, %{state | container_id: new_id}}
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call(:get_container_id, _from, state) do
    {:reply, {:error, :not_ready}, state}
  end

  @impl GenServer
  def handle_cast(:stop_task, %__MODULE__{} = state) do
    remove_container(state.container_id)
    clear_runner_handle(state.task_id)
    {:stop, :normal, state}
  end

  # Redact secret values from the state dumped by GenServer
  # crash logs. The Spec's `secrets` list otherwise gets
  # inspect()'d verbatim — including API keys.
  @impl GenServer
  def format_status(status) do
    update_in(status.state.spec, &Spec.redact/1)
  end

  # --- Container lifecycle ---

  defp ensure_container(%__MODULE__{task_id: task_id, spec: spec}) do
    case load_task_handle(task_id) do
      {:ok, nil} ->
        create_and_persist(task_id, spec)

      {:ok, handle} ->
        if container_alive?(handle) do
          {:ok, handle}
        else
          Logger.info("DockerEngine.TaskContainer #{task_id}: stored container #{handle} is gone; recreating")

          create_and_persist(task_id, spec)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_and_persist(task_id, spec) do
    with {:ok, container_id} <- create_container(task_id, spec),
         :ok <- start_container(container_id) do
      case persist_runner_handle(task_id, container_id) do
        :ok ->
          {:ok, container_id}

        {:error, reason} ->
          Logger.warning("DockerEngine.TaskContainer #{task_id}: persist failed: #{inspect(reason)}")

          {:ok, container_id}
      end
    end
  end

  defp create_container(task_id, %Spec{} = spec) do
    case do_create_container(task_id, spec) do
      {:error, {:create_failed, 404, %{"message" => "No such image:" <> _}}} ->
        Logger.info(
          "DockerEngine.TaskContainer #{task_id}: image #{inspect(spec.image)} " <>
            "not present locally; pulling"
        )

        with :ok <- pull_image(spec.image) do
          do_create_container(task_id, spec)
        end

      other ->
        other
    end
  end

  defp do_create_container(task_id, %Spec{} = spec) do
    name = Spec.task_runner_name(task_id)
    payload = container_create_payload(spec)

    case Req.post(DockerApi.request(),
           url: "/containers/create",
           params: [name: name],
           json: payload
         ) do
      {:ok, %Req.Response{status: status, body: %{"Id" => id}}} when status in 200..299 ->
        {:ok, id}

      {:ok, resp} ->
        {:error, {:create_failed, resp.status, resp.body}}

      {:error, _} = err ->
        err
    end
  end

  defp pull_image(nil), do: {:error, :no_image_to_pull}

  defp pull_image(ref) do
    # The Docker pull endpoint streams a JSON-lines progress body
    # and only returns 200 OK once the pull is fully complete. We
    # drain (and ignore) the body so we know when to retry create.
    # `fromImage` accepts the full reference including tag/digest
    # (e.g. `ghcr.io/org/name:tag`), so no need to split it.
    case Req.post(DockerApi.request(),
           url: "/images/create",
           params: [fromImage: ref],
           receive_timeout: 600_000,
           into: fn {:data, _chunk}, acc -> {:cont, acc} end
         ) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, resp} ->
        {:error, {:pull_failed, resp.status, resp.body}}

      {:error, _} = err ->
        err
    end
  end

  defp start_container(id) do
    case Req.post(DockerApi.request(), url: "/containers/#{id}/start") do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      {:ok, resp} -> {:error, {:start_failed, resp.status, resp.body}}
      {:error, _} = err -> err
    end
  end

  defp container_alive?(id) do
    case Req.get(DockerApi.request(), url: "/containers/#{id}/json") do
      {:ok, %Req.Response{status: 200, body: %{"State" => %{"Running" => true}}}} -> true
      _ -> false
    end
  end

  defp remove_container(nil), do: :ok

  defp remove_container(id) do
    Req.delete(DockerApi.request(), url: "/containers/#{id}", params: [force: true, v: true])
    :ok
  rescue
    _ -> :ok
  end

  # --- Persistence ---

  defp load_task_handle(task_id) do
    case Ash.get(Task, task_id) do
      {:ok, %Task{runner_handle: handle}} -> {:ok, handle}
      {:error, _} = err -> err
    end
  end

  defp persist_runner_handle(task_id, container_id) do
    case Ash.get(Task, task_id) do
      {:ok, task} ->
        case Ash.update(task, %{runner_handle: container_id}, action: :set_runner_handle) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, _} = err ->
        err
    end
  end

  defp clear_runner_handle(task_id) do
    case Ash.get(Task, task_id) do
      {:ok, task} ->
        Ash.update(task, %{}, action: :clear_runner_handle)
        :ok

      _ ->
        :ok
    end
  end

  # --- Container spec ---

  defp container_create_payload(%Spec{} = spec) do
    reject_nil(%{
      "Image" => spec.image || "alpine:latest",
      "Entrypoint" => ["/entrypoint.sh"],
      "Cmd" => ["sleep", "infinity"],
      "Env" => env_pairs(spec),
      "HostConfig" => %{"AutoRemove" => false, "Binds" => binds(spec)}
    })
  end

  defp env_pairs(%Spec{} = spec) do
    base = Enum.map(spec.env, fn {k, v} -> "#{k}=#{v}" end)
    secret_env = Enum.flat_map(spec.secrets, &secret_to_env/1)
    extras = bootstrap_env(spec) ++ repo_env(spec) ++ mcp_env(spec)

    base ++ secret_env ++ extras
  end

  defp secret_to_env(%{kind: :claude_api_key, value: v}), do: ["ANTHROPIC_API_KEY=#{v}"]
  defp secret_to_env(%{kind: :openai_api_key, value: v}), do: ["OPENAI_API_KEY=#{v}"]
  defp secret_to_env(%{kind: :codex_api_key, value: v}), do: ["OPENAI_API_KEY=#{v}"]

  defp secret_to_env(%{kind: kind, value: v}) when kind in [:github_pat, :github_oauth],
    do: ["GH_TOKEN=#{v}", "GITHUB_TOKEN=#{v}"]

  defp secret_to_env(%{kind: kind, value: v}) do
    ["CAMELOT_SECRET_#{String.upcase(Atom.to_string(kind))}=#{v}"]
  end

  defp bootstrap_env(%Spec{bootstrap?: true}), do: ["BOOTSTRAP=1"]
  defp bootstrap_env(_), do: []

  defp repo_env(%Spec{repo_url: nil}), do: []

  defp repo_env(%Spec{repo_url: url, repo_branch: branch}) do
    ["REPO_URL=#{url}"] ++ if(branch, do: ["REPO_BRANCH=#{branch}"], else: [])
  end

  defp mcp_env(%Spec{mcp_config_json: nil}), do: []
  defp mcp_env(%Spec{mcp_config_json: json}), do: ["PROJECT_MCP_CONFIG_JSON=#{json}"]

  defp binds(%Spec{profile_volume: nil}), do: []
  defp binds(%Spec{profile_volume: vol}), do: ["#{vol}:/home/agent:rw"]

  defp reject_nil(map) when is_map(map) do
    map
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new(fn {k, v} -> {k, reject_nil(v)} end)
  end

  defp reject_nil(other), do: other
end
