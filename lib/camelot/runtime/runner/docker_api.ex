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
  embedded DNS at first use and cache it. Cache is
  invalidated on a 503 response so we re-probe if the
  cluster's manager set changes.
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
  Drop the cached manager-proxy IP. Call after a 503
  from a management endpoint so the next `request/0`
  re-discovers — e.g. when a manager is demoted or its
  proxy task is rescheduled.
  """
  @spec invalidate_manager_proxy() :: :ok
  def invalidate_manager_proxy do
    :persistent_term.erase(@manager_proxy_key)
    :ok
  end

  defp docker_host do
    :camelot
    |> Application.fetch_env!(:runner)
    |> Keyword.fetch!(:docker_host)
  end

  defp tcp_request(host_and_port) do
    Req.new(base_url: "http://#{host_and_port}/#{@api_version}")
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
