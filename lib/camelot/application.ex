defmodule Camelot.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      CamelotWeb.Telemetry,
      Camelot.Repo,
      {DNSCluster, query: Application.get_env(:camelot, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Camelot.PubSub},
      # Start a worker by calling: Camelot.Worker.start_link(arg)
      # {Camelot.Worker, arg},
      # Start to serve requests, typically the last entry
      CamelotWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Camelot.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    CamelotWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
