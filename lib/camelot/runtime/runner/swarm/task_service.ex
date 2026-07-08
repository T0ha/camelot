defmodule Camelot.Runtime.Runner.Swarm.TaskService do
  @moduledoc """
  Long-lived GenServer that owns the Swarm service
  backing one Task. Sessions of that Task `docker exec`
  into the container running inside this service.

  Lifecycle:

    * `init/1` reads `Task.runner_handle`:
        - present & service alive → adopt
        - present & service gone → recreate
        - absent → `POST /services/create`, persist id
    * `stop_task/1` (cast) → `DELETE /services/<id>` +
      clear `runner_handle`, then stop normally.

  Registered under `Camelot.Runtime.Runner.Swarm.TaskRegistry`
  keyed by `task_id`. Multiple `ExecSession` siblings
  for the same task share this one process.
  """
  use GenServer, restart: :temporary

  alias Camelot.Board.Task
  alias Camelot.Runtime.Runner.DockerApi
  alias Camelot.Runtime.Runner.Spec
  alias Camelot.Runtime.SecretSync

  require Logger

  defstruct task_id: nil,
            spec: nil,
            service_id: nil,
            ensure_task: nil,
            waiters: []

  @type state :: %__MODULE__{
          task_id: String.t(),
          spec: Spec.t() | nil,
          service_id: String.t() | nil,
          ensure_task: Elixir.Task.t() | nil,
          waiters: [GenServer.from()]
        }

  # --- Public API ---

  @doc """
  Start (or look up) the TaskService for `spec.task_id`.
  Idempotent: a second caller with the same task_id gets
  the existing pid.
  """
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

  @doc """
  Look up the TaskService pid for `task_id` if running.
  """
  @spec lookup(String.t()) :: pid() | nil
  def lookup(task_id) do
    case Registry.lookup(registry(), task_id) do
      [{pid, _}] -> pid
      _ -> nil
    end
  end

  @doc """
  Return the Swarm service id. Blocks until the service
  is created or adopted; the GenServer parks the caller
  while the async ensure task runs.
  """
  @spec get_service_id(pid()) :: {:ok, String.t()} | {:error, term()}
  def get_service_id(pid) do
    GenServer.call(pid, :get_service_id, :infinity)
  end

  @doc """
  Tear down the service backing `task_id` and stop the
  GenServer. No-op when no TaskService is running.
  """
  @spec stop_task(String.t()) :: :ok
  def stop_task(task_id) do
    case lookup(task_id) do
      nil -> :ok
      pid -> GenServer.cast(pid, :stop_task)
    end

    :ok
  end

  @doc """
  Force swarm to redeploy the service's tasks without
  deleting the service. Used to recover a service that
  sits at `0/N` replicas after a transient node partition:
  bumps `Spec.TaskTemplate.ForceUpdate` and POSTs the
  current spec back, which makes swarm schedule a fresh
  replica on whatever node matches the constraints.

  Returns `{:error, :not_found}` if the service is genuinely
  gone (caller should recreate), or `{:error, reason}` on
  any other Docker API error.
  """
  @spec force_redeploy(String.t()) ::
          :ok | {:error, :not_found} | {:error, term()}
  def force_redeploy(service_id) when is_binary(service_id) do
    with {:ok, %{"Version" => %{"Index" => version}, "Spec" => spec}} <-
           fetch_service(service_id) do
      post_service_update(service_id, version, bump_force_update(spec))
    end
  end

  # --- GenServer plumbing ---

  @doc false
  def start_link(%Spec{task_id: task_id} = spec) when is_binary(task_id) do
    GenServer.start_link(__MODULE__, spec, name: via(task_id))
  end

  defp via(task_id), do: {:via, Registry, {registry(), task_id}}

  defp registry, do: Camelot.Runtime.Runner.Swarm.TaskRegistry

  defp supervisor, do: Camelot.Runtime.Runner.Swarm.TaskSupervisor

  @impl GenServer
  def init(%Spec{} = spec) do
    state = %__MODULE__{task_id: spec.task_id, spec: spec}
    {:ok, kick_off_ensure(state)}
  end

  @impl GenServer
  def handle_call(:get_service_id, from, %__MODULE__{service_id: nil} = state) do
    # Provisioning still in flight — park the caller.
    {:noreply, %{state | waiters: [from | state.waiters]}}
  end

  def handle_call(:get_service_id, from, %__MODULE__{service_id: id} = state) do
    if service_alive?(id) do
      {:reply, {:ok, id}, state}
    else
      Logger.info("Swarm.TaskService #{state.task_id}: cached service #{id} is gone; recreating")

      state = kick_off_ensure(%{state | service_id: nil, waiters: [from | state.waiters]})

      {:noreply, state}
    end
  end

  @impl GenServer
  def handle_cast(:stop_task, %__MODULE__{} = state) do
    remove_service(state.service_id)
    clear_runner_handle(state.task_id)
    {:stop, :normal, state}
  end

  @impl GenServer
  def handle_info({ref, result}, %__MODULE__{ensure_task: %Elixir.Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    case result do
      {:ok, service_id} ->
        Enum.each(state.waiters, &GenServer.reply(&1, {:ok, service_id}))
        {:noreply, %{state | service_id: service_id, ensure_task: nil, waiters: []}}

      {:error, reason} ->
        Enum.each(state.waiters, &GenServer.reply(&1, {:error, reason}))
        {:stop, reason, %{state | ensure_task: nil, waiters: []}}
    end
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %__MODULE__{ensure_task: %Elixir.Task{ref: ref}} = state) do
    Enum.each(state.waiters, &GenServer.reply(&1, {:error, {:ensure_crashed, reason}}))
    {:stop, reason, %{state | ensure_task: nil, waiters: []}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl GenServer
  def format_status(status) do
    update_in(status.state.spec, &Spec.redact/1)
  end

  # --- Service lifecycle ---

  defp kick_off_ensure(%__MODULE__{task_id: task_id, spec: spec} = state) do
    task = Elixir.Task.async(fn -> ensure_service(task_id, spec) end)
    %{state | ensure_task: task}
  end

  defp ensure_service(task_id, spec) do
    case load_task_handle(task_id) do
      {:ok, nil} ->
        create_and_persist(task_id, spec)

      {:ok, handle} ->
        if service_alive?(handle) do
          {:ok, handle}
        else
          Logger.info("Swarm.TaskService #{task_id}: stored handle #{handle} is gone; recreating")

          create_and_persist(task_id, spec)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_and_persist(task_id, spec) do
    case create_service(task_id, spec) do
      {:ok, service_id} ->
        case persist_runner_handle(task_id, service_id) do
          :ok ->
            {:ok, service_id}

          {:error, reason} ->
            Logger.warning(
              "Swarm.TaskService #{task_id}: persist runner_handle failed: " <>
                "#{inspect(reason)}; continuing with in-memory id"
            )

            {:ok, service_id}
        end

      {:error, _} = err ->
        err
    end
  end

  defp create_service(task_id, %Spec{} = spec) do
    name = Spec.task_runner_name(task_id)
    payload = service_create_payload(spec, name)

    case post_create(payload) do
      {:ok, id} ->
        {:ok, id}

      {:error, :name_conflict} ->
        Logger.info(
          "Swarm.TaskService #{task_id}: service name " <>
            "#{name} already exists; deleting stale " <>
            "service and retrying create"
        )

        delete_service_by_name(name)
        post_create_strict(payload)

      {:error, _} = err ->
        err
    end
  end

  defp post_create(payload) do
    case Req.post(DockerApi.request(), url: "/services/create", json: payload) do
      {:ok, %Req.Response{status: status, body: %{"ID" => id}}}
      when status in 200..299 ->
        {:ok, id}

      {:ok, %Req.Response{status: 409}} ->
        {:error, :name_conflict}

      {:ok, resp} ->
        {:error, {:create_failed, resp.status, resp.body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp post_create_strict(payload) do
    case post_create(payload) do
      {:ok, id} ->
        {:ok, id}

      {:error, :name_conflict} ->
        {:error, {:create_failed, 409, %{"message" => "service name still conflicts after delete-by-name retry"}}}

      {:error, _} = err ->
        err
    end
  end

  defp delete_service_by_name(name) do
    Req.delete(DockerApi.request(), url: "/services/#{name}")
    :ok
  rescue
    _ -> :ok
  end

  defp fetch_service(id) do
    case Req.get(DockerApi.request(), url: "/services/#{id}") do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
      {:ok, %Req.Response{status: 404}} -> {:error, :not_found}
      {:ok, resp} -> {:error, {:fetch_failed, resp.status, resp.body}}
      {:error, _} = err -> err
    end
  end

  defp bump_force_update(spec) do
    template = Map.get(spec, "TaskTemplate", %{})
    current = Map.get(template, "ForceUpdate", 0)
    Map.put(spec, "TaskTemplate", Map.put(template, "ForceUpdate", current + 1))
  end

  defp post_service_update(id, version, spec) do
    case Req.post(DockerApi.request(),
           url: "/services/#{id}/update",
           params: [version: version],
           json: spec
         ) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      {:ok, %Req.Response{status: 404}} -> {:error, :not_found}
      {:ok, resp} -> {:error, {:update_failed, resp.status, resp.body}}
      {:error, _} = err -> err
    end
  end

  # The service object alone isn't enough — a Swarm service whose
  # only replica was SIGKILLed (and RestartPolicy is "none") still
  # responds 200 here but has zero live tasks. Adopting that
  # corpse wedges `ExecSession.resolve_container/1` polling forever
  # for a task that will never appear. Require both that the
  # service exists AND that it has at least one task whose desired
  # state is "running"; anything else is treated as gone so
  # `create_and_persist/2` rebuilds it.
  defp service_alive?(service_id) do
    with {:ok, %Req.Response{status: 200}} <-
           Req.get(DockerApi.request(), url: "/services/#{service_id}"),
         {:ok, [_ | _]} <- list_runnable_tasks(service_id) do
      true
    else
      _ -> false
    end
  end

  defp list_runnable_tasks(service_id) do
    case Req.get(DockerApi.request(),
           url: "/tasks",
           params: [
             filters: ~s({"service":["#{service_id}"],"desired-state":["running"]})
           ]
         ) do
      {:ok, %Req.Response{status: 200, body: tasks}} when is_list(tasks) ->
        {:ok, tasks}

      {:ok, resp} ->
        {:error, {:tasks_bad_status, resp.status}}

      {:error, _} = err ->
        err
    end
  end

  defp remove_service(nil), do: :ok

  defp remove_service(id) do
    Req.delete(DockerApi.request(), url: "/services/#{id}")
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

  defp persist_runner_handle(task_id, service_id) do
    case Ash.get(Task, task_id) do
      {:ok, task} ->
        case Ash.update(task, %{runner_handle: service_id}, action: :set_runner_handle) do
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

  # --- Service spec construction ---

  @doc false
  # Public only so the payload can be asserted on in tests.
  @spec service_create_payload(Spec.t(), String.t()) :: map()
  def service_create_payload(%Spec{} = spec, name) do
    reject_nil(%{
      "Name" => name,
      "TaskTemplate" =>
        reject_nil(%{
          "ContainerSpec" => container_spec(spec),
          "Networks" => task_networks(),
          "Placement" => placement(spec),
          "Resources" => resources(spec),
          "RestartPolicy" => %{"Condition" => "none"}
        }),
      "Mode" => %{"Replicated" => %{"Replicas" => 1}}
    })
  end

  # Swarm resolves a service's DNS name (e.g. a CapRover
  # `srv-captain--db`) only for containers on the same overlay
  # network. Task runners land on the default bridge and so can't
  # reach such hostnames; operators list the overlays to join via the
  # `RUNNER_NETWORKS` env var (`:runner, :networks` config). Empty is
  # the default and correct for plain-Docker / non-Swarm self-hosting.
  defp task_networks do
    case configured_networks() do
      [] -> nil
      names -> Enum.map(names, &%{"Target" => &1})
    end
  end

  defp configured_networks do
    :camelot
    |> Application.get_env(:runner, [])
    |> Keyword.get(:networks, [])
  end

  defp container_spec(%Spec{} = spec) do
    reject_nil(%{
      "Image" => spec.image || "alpine:latest",
      "Command" => ["/entrypoint.sh", "sleep", "infinity"],
      "Env" => env_pairs(spec),
      "Mounts" => mounts(spec),
      "Secrets" => secrets(spec)
    })
  end

  defp env_pairs(%Spec{} = spec) do
    base = Enum.map(spec.env, fn {k, v} -> "#{k}=#{v}" end)
    base ++ bootstrap_env(spec) ++ repo_env(spec) ++ mcp_env(spec)
  end

  defp bootstrap_env(%Spec{bootstrap?: true}), do: ["BOOTSTRAP=1"]
  defp bootstrap_env(_), do: []

  defp repo_env(%Spec{repo_url: nil}), do: []

  defp repo_env(%Spec{repo_url: url, repo_branch: branch}) do
    ["REPO_URL=#{url}"] ++ if(branch, do: ["REPO_BRANCH=#{branch}"], else: [])
  end

  defp mcp_env(%Spec{mcp_config_json: nil}), do: []
  defp mcp_env(%Spec{mcp_config_json: json}), do: ["PROJECT_MCP_CONFIG_JSON=#{json}"]

  defp mounts(%Spec{profile_volume: nil}), do: []

  defp mounts(%Spec{profile_volume: vol}) do
    [
      %{
        "Target" => "/home/agent",
        "Source" => vol,
        "Type" => "volume",
        "ReadOnly" => false
      }
    ]
  end

  defp secrets(%Spec{secrets: []}), do: []

  defp secrets(%Spec{secrets: secrets}) do
    Enum.flat_map(secrets, fn %{kind: kind, name: name} ->
      case SecretSync.lookup_id_by_name(name) do
        {:ok, id} ->
          [
            %{
              "SecretID" => id,
              "SecretName" => name,
              "File" => %{
                "Name" => Atom.to_string(kind),
                "UID" => "1000",
                "GID" => "1000",
                "Mode" => 0o400
              }
            }
          ]

        :error ->
          Logger.warning(
            "Swarm.TaskService: secret #{name} not found; " <>
              "runner will start without /run/secrets/#{kind}"
          )

          []
      end
    end)
  end

  defp placement(%Spec{node_label: nil}), do: %{}

  defp placement(%Spec{node_label: label}) do
    %{"Constraints" => ["node.labels.camelot-home==#{label}"]}
  end

  defp resources(%Spec{resources: r}) when map_size(r) == 0, do: %{}

  defp resources(%Spec{resources: r}) do
    %{
      "Reservations" =>
        reject_nil(%{
          "NanoCPUs" => parse_cpu(r["cpu"]),
          "MemoryBytes" => parse_memory(r["memory"])
        })
    }
  end

  defp parse_cpu(nil), do: nil

  defp parse_cpu(value) when is_binary(value) do
    case Float.parse(value) do
      {f, _} -> trunc(f * 1_000_000_000)
      :error -> nil
    end
  end

  defp parse_memory(nil), do: nil

  defp parse_memory(value) when is_binary(value) do
    case Regex.run(~r/^(\d+)([GMK])?$/i, value) do
      [_, n, unit] -> String.to_integer(n) * unit_multiplier(unit)
      [_, n] -> String.to_integer(n)
      _ -> nil
    end
  end

  defp unit_multiplier(u) do
    case String.upcase(u) do
      "G" -> 1024 * 1024 * 1024
      "M" -> 1024 * 1024
      "K" -> 1024
      _ -> 1
    end
  end

  defp reject_nil(map) when is_map(map) do
    map
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end
end
