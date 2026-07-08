import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/camelot start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
alias Camelot.Runtime.Runner.Swarm

if System.get_env("PHX_SERVER") do
  config :camelot, CamelotWeb.Endpoint, server: true
end

# Overlay networks the task-runner services should join, comma-separated
# (e.g. "captain-overlay-network"), or "auto" to copy the networks the
# Camelot service is itself on. Needed on Swarm so runners can reach
# DB/service hostnames that only resolve on a shared overlay; empty (the
# default) is correct for plain-Docker / non-Swarm self-hosting.
runner_networks =
  "RUNNER_NETWORKS"
  |> System.get_env("")
  |> String.split(",", trim: true)
  |> Enum.map(&String.trim/1)
  |> Enum.reject(&(&1 == ""))

config :camelot, CamelotWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# Invite-only mode. When false, /sign-in rejects unknown emails; existing
# users can still receive magic links. Defaults to open so self-hosted
# installs work out of the box.
config :camelot,
  registration_enabled: System.get_env("REGISTRATION_ENABLED", "true") in ~w(true 1)

# Runner backend is overridable in every env via the RUNNER_BACKEND env
# var. Default differs by env: prod = swarm, dev/test = local.
if backend_env = System.get_env("RUNNER_BACKEND") do
  runner_backend =
    case backend_env do
      "swarm" -> Swarm
      "docker" -> Camelot.Runtime.Runner.DockerEngine
      "local" -> Camelot.Runtime.Runner.LocalPort
      other -> raise "unknown RUNNER_BACKEND: #{other}"
    end

  config :camelot, :runner,
    backend: runner_backend,
    docker_host: System.get_env("DOCKER_HOST", "unix:///var/run/docker.sock"),
    global_max: String.to_integer(System.get_env("RUNNER_GLOBAL_MAX", "20")),
    per_user_max: String.to_integer(System.get_env("RUNNER_PER_USER_MAX", "2")),
    networks: runner_networks
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  encryption_key =
    System.get_env("ENCRYPTION_KEY") ||
      raise """
      environment variable ENCRYPTION_KEY is missing.
      Generate one with: mix run -e 'IO.puts 32 |> :crypto.strong_rand_bytes() |> Base.encode64()'
      """

  # In prod, default to swarm if RUNNER_BACKEND wasn't set above.
  if !System.get_env("RUNNER_BACKEND") do
    config :camelot, :runner,
      backend: Swarm,
      docker_host: System.get_env("DOCKER_HOST", "unix:///var/run/docker.sock"),
      global_max: String.to_integer(System.get_env("RUNNER_GLOBAL_MAX", "20")),
      per_user_max: String.to_integer(System.get_env("RUNNER_PER_USER_MAX", "2")),
      networks: runner_networks
  end

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :camelot, CamelotWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :camelot, CamelotWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # Mailer: OCI Email Delivery via SMTP relay.
  smtp_relay =
    System.get_env("SMTP_RELAY") ||
      raise "environment variable SMTP_RELAY is missing (e.g. smtp.email.us-ashburn-1.oci.oraclecloud.com)"

  smtp_username =
    System.get_env("SMTP_USERNAME") ||
      raise "environment variable SMTP_USERNAME is missing (OCI SMTP credential username)"

  smtp_password =
    System.get_env("SMTP_PASSWORD") ||
      raise "environment variable SMTP_PASSWORD is missing (OCI SMTP credential password)"

  config :camelot, Camelot.Mailer,
    adapter: Swoosh.Adapters.SMTP,
    relay: smtp_relay,
    port: String.to_integer(System.get_env("SMTP_PORT") || "587"),
    username: smtp_username,
    password: smtp_password,
    tls: :always,
    tls_options: [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      server_name_indication: String.to_charlist(smtp_relay),
      depth: 99
    ],
    auth: :always,
    retries: 1,
    no_mx_lookups: false

  config :camelot, Camelot.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  config :camelot, Camelot.Vault,
    ciphers: [
      default: {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: Base.decode64!(encryption_key), iv_length: 12}
    ]

  config :camelot, CamelotWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  config :camelot, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :camelot, :mail,
    from_name: System.get_env("MAIL_FROM_NAME") || "Camelot AI",
    from_address:
      System.get_env("MAIL_FROM") ||
        raise("environment variable MAIL_FROM is missing (e.g. noreply@camelotai.tech)")
end
