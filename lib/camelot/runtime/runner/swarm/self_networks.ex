defmodule Camelot.Runtime.Runner.Swarm.SelfNetworks do
  @moduledoc """
  Auto-discovers the overlay networks the Camelot service itself is
  attached to, so task-runner services can be placed on the same
  networks and inherit identical service-to-service reachability —
  e.g. reaching a CapRover `srv-captain--db` DB host that only resolves
  on a shared overlay.

  Enabled with `RUNNER_NETWORKS=auto`. Discovery walks:

    1. own container id — the container hostname (Swarm sets it to the
       container's short id unless overridden);
    2. `GET /tasks` — find the running task whose container id matches,
       read its `ServiceID`;
    3. `GET /services/<id>` — copy that service's own
       `TaskTemplate.Networks` targets.

  A successful (non-empty) result is memoized in `:persistent_term`,
  since the app's own network attachments only change on a redeploy —
  which restarts the app and clears the term. Failures and empty
  results are not cached, so a transient Docker API hiccup at boot is
  retried on the next runner launch.
  """

  alias Camelot.Runtime.Runner.DockerApi

  require Logger

  @cache_key {__MODULE__, :targets}

  @doc """
  Returns the network targets to attach runners to, discovering them on
  the first call and serving the memoized result thereafter. Returns
  `[]` (and logs) when discovery can't complete — runner creation then
  proceeds with no extra network rather than failing.
  """
  @spec discover() :: [String.t()]
  def discover do
    case :persistent_term.get(@cache_key, :miss) do
      :miss -> discover_and_maybe_cache()
      targets -> targets
    end
  end

  @doc """
  Forget any memoized discovery result so the next `discover/0`
  re-probes. Exposed for operators (force a re-scan) and tests.
  """
  @spec reset_cache() :: :ok
  def reset_cache do
    :persistent_term.erase(@cache_key)
    :ok
  end

  @doc false
  # Seed the memo directly. Used by tests to exercise the `auto` wiring
  # without a live Docker daemon.
  @spec put_cache([String.t()]) :: :ok
  def put_cache(targets) when is_list(targets) do
    :persistent_term.put(@cache_key, targets)
    :ok
  end

  # --- Pure discovery logic (unit-tested) ---

  @doc """
  Finds the `ServiceID` of the task whose container id is prefixed by
  `container_id` (the daemon stores the full id; the hostname is the
  short form). Returns `nil` when no task matches.
  """
  @spec find_own_service_id([map()], String.t()) :: String.t() | nil
  def find_own_service_id(tasks, container_id) do
    Enum.find_value(tasks, &own_service_id(&1, container_id))
  end

  defp own_service_id(_task, ""), do: nil

  defp own_service_id(task, container_id) do
    cid = get_in(task, ["Status", "ContainerStatus", "ContainerID"]) || ""

    if String.starts_with?(cid, container_id) do
      task["ServiceID"]
    end
  end

  @doc """
  Extracts the network targets from a service object's own
  `TaskTemplate.Networks`, dropping any entry without a `Target`.
  """
  @spec targets_from_service(map()) :: [String.t()]
  def targets_from_service(service) do
    service
    |> get_in(["Spec", "TaskTemplate", "Networks"])
    |> List.wrap()
    |> Enum.map(& &1["Target"])
    |> Enum.reject(&is_nil/1)
  end

  # --- HTTP glue (thin, matches the untested-HTTP convention) ---

  defp discover_and_maybe_cache do
    case do_discover() do
      [] -> []
      targets -> tap(targets, &put_cache/1)
    end
  end

  defp do_discover do
    with {:ok, id} <- own_container_id(),
         {:ok, tasks} <- fetch_running_tasks(),
         service_id when is_binary(service_id) <- find_own_service_id(tasks, id),
         {:ok, service} <- fetch_service(service_id) do
      targets_from_service(service)
    else
      other ->
        Logger.warning(
          "Swarm.SelfNetworks: could not auto-discover networks " <>
            "(#{inspect(other)}); runners will start with no extra network"
        )

        []
    end
  end

  defp own_container_id do
    case :inet.gethostname() do
      {:ok, name} -> {:ok, List.to_string(name)}
      other -> {:error, {:hostname, other}}
    end
  end

  defp fetch_running_tasks do
    case Req.get(DockerApi.request(),
           url: "/tasks",
           params: [filters: ~s({"desired-state":["running"]})]
         ) do
      {:ok, %Req.Response{status: 200, body: tasks}} when is_list(tasks) ->
        {:ok, tasks}

      {:ok, resp} ->
        {:error, {:tasks_bad_status, resp.status}}

      {:error, _} = err ->
        err
    end
  end

  defp fetch_service(id) do
    case Req.get(DockerApi.request(), url: "/services/#{id}") do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
      {:ok, resp} -> {:error, {:service_bad_status, resp.status}}
      {:error, _} = err -> err
    end
  end
end
