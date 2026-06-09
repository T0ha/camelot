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
      Camelot.Vault,
      {DNSCluster, query: Application.get_env(:camelot, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Camelot.PubSub},
      {Oban,
       AshOban.config(
         Application.fetch_env!(:camelot, :ash_domains),
         Application.fetch_env!(:camelot, Oban)
       )},
      {AshAuthentication.Supervisor, otp_app: :camelot},
      Camelot.Runtime.AgentRegistry,
      Camelot.Runtime.SessionRegistry,
      {Registry, keys: :unique, name: Camelot.Runtime.Runner.Swarm.TaskRegistry},
      {DynamicSupervisor, name: Camelot.Runtime.Runner.Swarm.TaskSupervisor, strategy: :one_for_one},
      {Registry, keys: :unique, name: Camelot.Runtime.Runner.DockerEngine.TaskRegistry},
      {DynamicSupervisor, name: Camelot.Runtime.Runner.DockerEngine.TaskSupervisor, strategy: :one_for_one},
      Camelot.Runtime.RunnerPool,
      Camelot.Runtime.SecretSync,
      Camelot.Runtime.AgentSupervisor,
      Camelot.Runtime.Reconciler,
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
