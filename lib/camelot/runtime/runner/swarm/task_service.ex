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
  alias Camelot.Runtime.Runner.ImageRef
  alias Camelot.Runtime.Runner.RegistryClient
  alias Camelot.Runtime.Runner.Spec
  alias Camelot.Runtime.Runner.Swarm.SelfNetworks
  alias Camelot.Runtime.SecretSync

  require Logger

  # The runner container is a long-lived `sleep infinity` host that
  # sessions exec into, so a replica that dies has taken the whole task
  # runner with it. `none` used to be the policy, which meant a single
  # failed start — a node briefly out of memory, a pull that timed out —
  # left the service alive at zero replicas with nothing to bring it
  # back, and the reconciler eventually gave up on the task. A bounded
  # `on-failure` lets Swarm retry a few times on its own; the reconciler
  # still catches the case where every attempt fails.
  @restart_policy %{
    "Condition" => "on-failure",
    "MaxAttempts" => 3,
    "Delay" => 5_000_000_000
  }

  # Bounded wait for Swarm to finish tearing a stale service down
  # before its secrets can be rotated (~2s worst case).
  @stale_service_attempts 8
  @stale_service_poll_ms 250

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

  @doc """
  Pin a service's floating-tag image to the newest published
  digest, in place. Best-effort and idempotent:

    * pinned images (`:1.19`, or a digest with no tag) are left
      untouched;
    * for a floating image (`latest` or no tag) the current
      registry digest is resolved and, only when it differs from
      the digest the service already runs, the spec is POSTed back
      with a fully digest-pinned image so Swarm rolls the container.

  Called by the Reconciler's boot sweep. Never raises, so one bad
  service can't abort the sweep.

  Returns `:rolled` when Swarm was actually asked to replace the
  container — the caller needs to know, because that destroys the
  container's `/tmp` and with it the tee'd output and completion
  marker any in-flight session depends on. `:unchanged` means the
  service was already on the current digest (or is deliberately
  pinned) and nothing moved.
  """
  @spec autoupdate_image(String.t()) :: :rolled | :unchanged | {:error, term()}
  def autoupdate_image(service_ref) when is_binary(service_ref) do
    with {:ok, %{"Version" => %{"Index" => version}, "Spec" => spec}} <-
           fetch_service(service_ref),
         image when is_binary(image) <- get_in(spec, ["TaskTemplate", "ContainerSpec", "Image"]),
         true <- ImageRef.floating?(image),
         {:ok, digest} <- RegistryClient.current_digest(image) do
      apply_image_update(service_ref, version, plan_pinned_update(spec, image, digest))
    else
      {:error, reason} ->
        Logger.warning("Swarm.TaskService autoupdate_image #{service_ref}: #{inspect(reason)}")

        {:error, reason}

      _pinned_or_missing ->
        :unchanged
    end
  end

  defp apply_image_update(service_ref, version, {:update, new_spec}) do
    log_autoupdate(service_ref, post_service_update(service_ref, version, new_spec))
  end

  defp apply_image_update(_service_ref, _version, :unchanged), do: :unchanged

  defp log_autoupdate(service_ref, :ok) do
    Logger.info("Swarm.TaskService autoupdate_image #{service_ref}: pinned newest digest")
    :rolled
  end

  defp log_autoupdate(service_ref, {:error, reason}) do
    Logger.warning(
      "Swarm.TaskService autoupdate_image #{service_ref}: " <>
        "update failed: #{inspect(reason)}"
    )

    {:error, reason}
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

  # The image is resolved to an explicit digest here rather than left as
  # a bare tag: the Docker API stores whatever string it is given, so a
  # service created with `:latest` looks "unpinned" to the boot sweep,
  # which then rolls its container on the next redeploy even when the
  # image never moved. Resolving up front makes that sweep a genuine
  # no-op unless a newer image really was published.
  defp create_service(task_id, %Spec{} = spec) do
    name = Spec.task_runner_name(task_id)

    with :ok <- clear_stale_service(task_id, name),
         :ok <- rotate_task_secrets(task_id, spec) do
      post_create_named(task_id, name, spec)
    end
  end

  defp post_create_named(task_id, name, spec) do
    payload = service_create_payload(pin_image(spec), name)

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

  # Docker refuses to delete a secret while any service still
  # references it, and a Swarm secret can only be rotated by
  # delete-then-create. So a re-dispatch that finds the previous run's
  # service still registered under this name cannot refresh the task's
  # secrets — and a GitHub App installation token is dead an hour after
  # it was minted, which the runner only discovers as a `git clone`
  # 401 that kills the container at boot. Sweep the corpse first, then
  # rotate, then build the payload that resolves the SecretIDs.
  defp clear_stale_service(task_id, name) do
    case fetch_service(name) do
      {:error, :not_found} ->
        :ok

      _ ->
        Logger.info(
          "Swarm.TaskService #{task_id}: removing stale service " <>
            "#{name} so its secrets can be rotated"
        )

        delete_service_by_name(name)
        await_service_gone(name, @stale_service_attempts)
    end
  end

  # `DELETE /services` returns before Swarm has released the service's
  # hold on its secrets, so poll until the service is really gone.
  # Bounded — give up and report rather than block the create forever.
  defp await_service_gone(name, 0), do: {:error, {:stale_service_present, name}}

  defp await_service_gone(name, attempts) do
    case fetch_service(name) do
      {:error, :not_found} ->
        :ok

      _ ->
        Process.sleep(@stale_service_poll_ms)
        await_service_gone(name, attempts - 1)
    end
  end

  # Only the task's own secrets are rotated here. Per-user secrets are
  # owned by `SecretSync.reconcile/2` and may legitimately be pinned by
  # another task's live runner — not this task's problem, and unlike an
  # installation token they do not expire on their own.
  defp rotate_task_secrets(task_id, %Spec{} = spec) do
    spec
    |> task_scoped_secrets(task_id)
    |> Enum.reduce_while(:ok, fn secret, _acc ->
      case rotate_secret(secret) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp rotate_secret(%{kind: kind, name: name, value: value}) do
    case SecretSync.put_secret(name, value) do
      {:ok, _id} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Swarm.TaskService: rotating #{name} failed " <>
            "(#{inspect(reason)}); refusing to start a runner that " <>
            "would mount a stale #{kind}"
        )

        {:error, {:secret_rotation_failed, name, reason}}
    end
  end

  @doc false
  # The secrets this task owns — the ones named after the task rather
  # than after its user. Public (with `@doc false`) so the ownership
  # rule is unit-testable without a Docker API.
  @spec task_scoped_secrets(Spec.t(), String.t()) :: [Spec.secret()]
  def task_scoped_secrets(%Spec{secrets: secrets}, task_id) do
    Enum.filter(secrets, &task_scoped?(&1, task_id))
  end

  defp task_scoped?(%{kind: kind, name: name}, task_id) do
    name == SecretSync.task_secret_name(task_id, kind)
  end

  defp pin_image(%Spec{image: image} = spec) do
    %{spec | image: RegistryClient.pinned_ref(image)}
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

  @doc false
  # Public only so the digest-comparison decision can be asserted on
  # in tests. Given a live service `Spec` map, the service's current
  # image string, and the digest its tag now resolves to: returns
  # `:unchanged` when the service already runs that digest, or
  # `{:update, spec}` with the image pinned to the new digest.
  @spec plan_pinned_update(map(), String.t(), String.t()) :: {:update, map()} | :unchanged
  def plan_pinned_update(spec, image, digest) do
    case ImageRef.parse(image).digest do
      ^digest ->
        :unchanged

      _ ->
        {:update, put_in(spec, ["TaskTemplate", "ContainerSpec", "Image"], ImageRef.pin(image, digest))}
    end
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
          "RestartPolicy" => @restart_policy
        }),
      "Mode" => %{"Replicated" => %{"Replicas" => 1}}
    })
  end

  # Swarm resolves a service's DNS name (e.g. a CapRover
  # `srv-captain--db`) only for containers on the same overlay
  # network. Task runners land on the default bridge and so can't
  # reach such hostnames. The `RUNNER_NETWORKS` env var
  # (`:runner, :networks` config) controls which overlays they join;
  # it defaults to `auto` (copy the networks the Camelot service is
  # itself on). `none` keeps runners isolated.
  defp task_networks do
    case configured_networks() do
      [] -> nil
      names -> Enum.map(names, &%{"Target" => &1})
    end
  end

  defp configured_networks do
    :camelot
    |> Application.get_env(:runner, [])
    |> Keyword.get(:networks, ["auto"])
    |> resolve_networks()
  end

  # `auto` is replaced with the networks discovered from the Camelot
  # service itself (explicit entries alongside it are kept); `none`
  # forces isolation regardless of other entries.
  defp resolve_networks(names) do
    resolve_networks(names, "auto" in names, "none" in names)
  end

  defp resolve_networks(names, true, _none) do
    Enum.uniq(SelfNetworks.discover() ++ (names -- ["auto", "none"]))
  end

  defp resolve_networks(_names, false, true), do: []
  defp resolve_networks(names, false, false), do: names

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
    base ++ bootstrap_env(spec) ++ repo_env(spec) ++ mcp_env(spec) ++ attachments_env(spec)
  end

  defp bootstrap_env(%Spec{bootstrap?: true}), do: ["BOOTSTRAP=1"]
  defp bootstrap_env(_), do: []

  defp repo_env(%Spec{repo_url: nil}), do: []

  defp repo_env(%Spec{repo_url: url, repo_branch: branch}) do
    ["REPO_URL=#{url}"] ++ if(branch, do: ["REPO_BRANCH=#{branch}"], else: [])
  end

  defp mcp_env(%Spec{mcp_config_json: nil}), do: []
  defp mcp_env(%Spec{mcp_config_json: json}), do: ["PROJECT_MCP_CONFIG_JSON=#{json}"]

  defp attachments_env(%Spec{attachments_json: nil}), do: []
  defp attachments_env(%Spec{attachments_json: json}), do: ["ATTACHMENTS_JSON=#{json}"]

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
    Enum.flat_map(secrets, &secret_mount/1)
  end

  # Env-only marker (blanks GH_TOKEN in the exec); nothing to mount.
  defp secret_mount(%{kind: :github_token_clear}), do: []

  defp secret_mount(%{kind: kind, name: name}) do
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
