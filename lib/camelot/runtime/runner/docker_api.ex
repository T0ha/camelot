defmodule Camelot.Runtime.Runner.DockerApi do
  @moduledoc """
  Thin wrapper around the Docker Engine + Swarm HTTP
  API using `Req`. Supports both unix-socket
  (`unix:///var/run/docker.sock`) and TCP
  (`tcp://host:port`) transports, chosen from the
  `:runner` application config.

  When the configured host is a Swarm overlay service
  name (the global `docker-socket-proxy`), management
  calls (`/services`, `/tasks`, `/secrets`, `/nodes`)
  must reach a manager-hosted proxy task — workers'
  daemons 503 on cluster-state endpoints. We resolve a
  manager-hosted proxy task's overlay IP via Swarm's
  embedded DNS at first use and cache it.

  The cache self-heals: every request built for the proxy
  transport carries response/error steps that drop the
  cached IP when a call comes back `503` (the cached IP is
  a worker proxy) or fails with a transport error such as
  `:ehostunreach`/`:timeout` (the proxy task was
  rescheduled to a new overlay IP after a redeploy). The
  next `request/0` then re-discovers a live manager proxy.
  Without this, a proxy reschedule would strand every
  management call on a dead IP until the app restarted.
  """

  require Logger

  @api_version "v1.43"
  @manager_proxy_key {__MODULE__, :manager_proxy_ip}
  @probe_timeout_ms 5_000

  @doc """
  Builds a `Req.Request` baseline pointed at the
  configured Docker host. Callers attach path, method,
  json, etc. via standard `Req` options.
  """
  @spec request() :: Req.Request.t()
  def request do
    case docker_host() do
      "unix://" <> path ->
        Req.new(base_url: "http://localhost/#{@api_version}", unix_socket: path)

      "tcp://" <> rest ->
        rest |> resolve_manager_host() |> tcp_request()

      "http://" <> _ = url ->
        Req.new(base_url: "#{url}/#{@api_version}")

      "https://" <> _ = url ->
        Req.new(base_url: "#{url}/#{@api_version}")

      other ->
        raise "unsupported DOCKER_HOST: #{inspect(other)}"
    end
  end

  @doc """
  Returns `:ok` if the daemon answers `/_ping`.
  Used by SecretSync/Reconciler on boot to decide
  whether the Swarm/Docker backends are usable.
  """
  @spec ping() :: :ok | {:error, term()}
  def ping do
    case Req.get(request(), url: "/_ping") do
      {:ok, %Req.Response{status: 200}} -> :ok
      {:ok, resp} -> {:error, {:bad_status, resp.status}}
      {:error, _} = err -> err
    end
  end

  @doc """
  Drop the cached manager-proxy IP so the next `request/0`
  re-discovers — e.g. when a manager is demoted or its
  proxy task is rescheduled. Called automatically by the
  self-healing request steps (see `stale_proxy?/1`); also
  safe to call directly.
  """
  @spec invalidate_manager_proxy() :: :ok
  def invalidate_manager_proxy do
    :persistent_term.erase(@manager_proxy_key)
    :ok
  end

  @doc """
  Returns `true` when a proxy response/error means the
  cached proxy IP is stale and should be dropped so the
  next call re-resolves: a transport failure (the proxy
  task was rescheduled to a new overlay IP —
  `:ehostunreach`, `:timeout`, `:econnrefused`, ...) or a
  `503` (the cached IP is a worker proxy that can't serve
  cluster-state endpoints).
  """
  @spec stale_proxy?(Req.Response.t() | Exception.t()) :: boolean()
  def stale_proxy?(%Req.Response{status: 503}), do: true
  def stale_proxy?(%Req.TransportError{}), do: true
  def stale_proxy?(_other), do: false

  @doc false
  # Response/error step: drops the cached manager-proxy IP
  # when the result signals a stale proxy, then passes the
  # result through unchanged. Public only so the wiring can
  # be asserted on in tests.
  @spec drop_stale_manager_proxy({Req.Request.t(), Req.Response.t() | Exception.t()}) ::
          {Req.Request.t(), Req.Response.t() | Exception.t()}
  def drop_stale_manager_proxy({_request, result} = acc) do
    maybe_invalidate_manager(stale_proxy?(result))
    acc
  end

  defp maybe_invalidate_manager(true), do: invalidate_manager_proxy()
  defp maybe_invalidate_manager(false), do: :ok

  @doc """
  Lists the distinct `camelot-home` label values currently set
  on live Swarm nodes, sorted. Only nodes an operator has
  already labelled via `docker node update --label-add
  camelot-home=<value>` (see `docs/cluster-runners.md`) are
  valid `Spec.node_label` targets, so this powers the node-pin
  dropdowns in the admin UI. Fails fast (rather than hanging a
  page load) when the daemon isn't reachable or isn't a Swarm
  manager — callers should fall back to free-text entry on
  `{:error, _}`.
  """
  @spec list_node_labels() :: {:ok, [String.t()]} | {:error, term()}
  def list_node_labels do
    case Req.get(request(), url: "/nodes", receive_timeout: @probe_timeout_ms) do
      {:ok, %Req.Response{status: 200, body: nodes}} when is_list(nodes) ->
        {:ok, extract_node_labels(nodes)}

      {:ok, resp} ->
        {:error, {:list_nodes_failed, resp.status, resp.body}}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Same as `list_node_labels/0`, but collapses any error into an
  empty list — the form admin LiveViews call directly to decide
  between the node-label dropdown and the free-text fallback.
  """
  @spec list_node_labels_or_empty() :: [String.t()]
  def list_node_labels_or_empty do
    case list_node_labels() do
      {:ok, labels} -> labels
      {:error, _} -> []
    end
  end

  @doc false
  # Public only so parsing can be asserted on in tests.
  @spec extract_node_labels([map()]) :: [String.t()]
  def extract_node_labels(nodes) do
    nodes
    |> Enum.flat_map(&node_label/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp node_label(%{"Spec" => %{"Labels" => %{"camelot-home" => label}}}) when is_binary(label) and label != "" do
    [label]
  end

  defp node_label(_node), do: []

  defp docker_host do
    :camelot
    |> Application.fetch_env!(:runner)
    |> Keyword.fetch!(:docker_host)
  end

  defp tcp_request(host_and_port) do
    [base_url: "http://#{host_and_port}/#{@api_version}"]
    |> Req.new()
    |> Req.Request.append_response_steps(camelot_stale_proxy: &drop_stale_manager_proxy/1)
    |> Req.Request.append_error_steps(camelot_stale_proxy: &drop_stale_manager_proxy/1)
  end

  # If the configured host is a Swarm service name on the
  # default proxy port, swap in a manager-hosted task's
  # overlay IP. For any other host (custom port, raw IP,
  # localhost-on-2376, etc.) leave it alone.
  defp resolve_manager_host(rest) do
    case String.split(rest, ":", parts: 2) do
      [host, "2375"] ->
        case manager_proxy_ip(host) do
          {:ok, ip} -> "#{ip}:2375"
          :error -> rest
        end

      _ ->
        rest
    end
  end

  defp manager_proxy_ip(service_host) do
    case :persistent_term.get(@manager_proxy_key, nil) do
      nil -> discover_manager_proxy(service_host)
      ip when is_binary(ip) -> {:ok, ip}
    end
  end

  defp discover_manager_proxy(service_host) do
    with {:ok, ips} <- resolve_task_ips(service_host),
         ip when is_binary(ip) <- Enum.find(ips, &manager_proxy?/1) do
      :persistent_term.put(@manager_proxy_key, ip)
      {:ok, ip}
    else
      _ -> :error
    end
  end

  defp resolve_task_ips(service_host) do
    case :inet_res.lookup(~c"tasks.#{service_host}", :in, :a) do
      [] -> :error
      addrs when is_list(addrs) -> {:ok, Enum.map(addrs, &ip_to_string/1)}
    end
  end

  defp ip_to_string({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"

  # Manager-node proxy: returns 200 for /nodes. Worker
  # proxy: 503 because workers don't carry cluster state.
  defp manager_proxy?(ip) do
    req = Req.new(base_url: "http://#{ip}:2375/#{@api_version}", receive_timeout: @probe_timeout_ms)

    case Req.get(req, url: "/nodes") do
      {:ok, %Req.Response{status: 200}} -> true
      _ -> false
    end
  end
end
