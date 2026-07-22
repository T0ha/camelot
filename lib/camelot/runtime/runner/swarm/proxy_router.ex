defmodule Camelot.Runtime.Runner.Swarm.ProxyRouter do
  @moduledoc """
  Resolves the `docker-socket-proxy` task running on a
  given Swarm node and hands back a `Req` client that
  targets that task's overlay IP directly.

  Why: the proxy is deployed as a global Swarm service
  (one task per node), but the per-task runner services
  can land on any node. `docker exec` only works against
  the daemon on the node hosting the target container —
  so each exec must be routed to the proxy task on the
  *same* node as the target container, bypassing
  Swarm's load-balancing VIP.

  Cache: results are stored in `:persistent_term` keyed
  by `node_id`. Each entry is the overlay IP of the
  proxy task on that node. Reads are zero-overhead.

  The cache self-heals: the `Req` client handed back for a
  node carries response/error steps that drop that node's
  cached IP whenever a call returns `503` or fails with a
  transport error such as `:ehostunreach`/`:timeout` — the
  proxy task was rescheduled to a new overlay IP. The next
  `request_for_node/1` then re-resolves via `GET /tasks`.
  """

  alias Camelot.Runtime.Runner.DockerApi

  require Logger

  @proxy_service_name "srv-captain--docker-socket-proxy"
  @cache_key {__MODULE__, :proxy_ips}

  @doc """
  Returns a `Req` client targeting the proxy task on
  `node_id`. Falls back to the manager's proxy (the
  default `DockerApi.request/0`) when the per-node
  resolution fails — Swarm operations like
  `GET /tasks` work against any manager proxy, so
  control-plane reads still work; only exec requests
  truly need per-node routing.
  """
  @spec request_for_node(String.t()) :: {:ok, Req.Request.t()} | {:error, term()}
  def request_for_node(node_id) when is_binary(node_id) do
    case Map.fetch(get_cache(), node_id) do
      {:ok, ip} ->
        {:ok, req_for_ip(ip, node_id)}

      :error ->
        case resolve_ip(node_id) do
          {:ok, ip} ->
            put_cache(Map.put(get_cache(), node_id, ip))
            {:ok, req_for_ip(ip, node_id)}

          {:error, _} = err ->
            err
        end
    end
  end

  @doc """
  Drop the cached proxy IP for `node_id`. Happens
  automatically via the request's self-healing steps when a
  call returns `503` or fails with a transport error
  (`:ehostunreach`, `:timeout`, `:econnrefused`, ...) — the
  proxy task was rescheduled and its overlay IP changed.
  Also safe to call directly.
  """
  @spec invalidate(String.t()) :: :ok
  def invalidate(node_id) do
    put_cache(Map.delete(get_cache(), node_id))
    :ok
  end

  @doc false
  # Response/error step: drops this node's cached proxy IP
  # when the result signals a stale proxy, then passes the
  # result through unchanged. Public only so the wiring can
  # be asserted on in tests.
  @spec drop_stale_node_proxy(
          {Req.Request.t(), Req.Response.t() | Exception.t()},
          String.t()
        ) :: {Req.Request.t(), Req.Response.t() | Exception.t()}
  def drop_stale_node_proxy({_request, result} = acc, node_id) do
    maybe_invalidate_node(DockerApi.stale_proxy?(result), node_id)
    acc
  end

  defp maybe_invalidate_node(true, node_id), do: invalidate(node_id)
  defp maybe_invalidate_node(false, _node_id), do: :ok

  defp get_cache, do: :persistent_term.get(@cache_key, %{})
  defp put_cache(map), do: :persistent_term.put(@cache_key, map)

  defp req_for_ip(ip, node_id) do
    [base_url: "http://#{ip}:2375/v1.43"]
    |> Req.new()
    |> Req.Request.append_response_steps(camelot_stale_proxy: &drop_stale_node_proxy(&1, node_id))
    |> Req.Request.append_error_steps(camelot_stale_proxy: &drop_stale_node_proxy(&1, node_id))
  end

  defp resolve_ip(node_id) do
    filters = ~s({"service":["#{@proxy_service_name}"]})

    case Req.get(DockerApi.request(), url: "/tasks", params: [filters: filters]) do
      {:ok, %Req.Response{status: 200, body: tasks}} when is_list(tasks) ->
        case proxy_ip_for_node(tasks, node_id) do
          nil ->
            Logger.warning("ProxyRouter: no proxy task on node #{node_id}")
            {:error, :no_proxy_on_node}

          ip ->
            {:ok, ip}
        end

      {:ok, resp} ->
        {:error, {:bad_status, resp.status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Picks the overlay IP of the *desired-running* proxy task on
  `node_id` from a Docker `GET /tasks` list, or `nil`.

  Requires `DesiredState == "running"` so a rescheduled proxy's
  orphaned old task — which can linger in `Status.State ==
  "running"` advertising a stale overlay IP — is never chosen.
  Routing to that IP would produce endless transport errors.
  """
  @spec proxy_ip_for_node([map()], String.t()) :: String.t() | nil
  def proxy_ip_for_node(tasks, node_id) do
    tasks
    |> Enum.find(&match_running_on_node?(&1, node_id))
    |> extract_overlay_ip()
  end

  defp match_running_on_node?(task, node_id) do
    task["NodeID"] == node_id and
      task["DesiredState"] == "running" and
      get_in(task, ["Status", "State"]) == "running"
  end

  defp extract_overlay_ip(nil), do: nil

  defp extract_overlay_ip(task) do
    Enum.find_value(task["NetworksAttachments"] || [], fn att ->
      case att["Addresses"] do
        [addr | _] -> addr |> String.split("/") |> List.first()
        _ -> nil
      end
    end)
  end
end
