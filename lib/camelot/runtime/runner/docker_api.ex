defmodule Camelot.Runtime.Runner.DockerApi do
  @moduledoc """
  Thin wrapper around the Docker Engine + Swarm HTTP
  API using `Req`. Supports both unix-socket
  (`unix:///var/run/docker.sock`) and TCP
  (`tcp://host:port`) transports, chosen from the
  `:runner` application config.

  Used by both the `DockerEngine` and `Swarm` runner
  backends, and by `SecretSync` for Swarm secret CRUD.
  """

  require Logger

  @api_version "v1.43"

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
        Req.new(base_url: "http://#{rest}/#{@api_version}")

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

  defp docker_host do
    :camelot
    |> Application.fetch_env!(:runner)
    |> Keyword.fetch!(:docker_host)
  end
end
