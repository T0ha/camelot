import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
default_database_url =
  "ecto://#{System.get_env("DATABASE_USER", "postgres")}:" <>
    "#{System.get_env("DATABASE_PASSWORD", "postgres")}@" <>
    "#{System.get_env("DATABASE_HOST", "localhost")}:" <>
    "#{System.get_env("DATABASE_PORT", "5432")}/camelot_test#{System.get_env("MIX_TEST_PARTITION")}"

# Faster bcrypt for tests
config :bcrypt_elixir, log_rounds: 1

# In test we don't send emails
config :camelot, Camelot.Mailer, adapter: Swoosh.Adapters.Test

config :camelot, Camelot.Repo,
  url: System.get_env("DATABASE_URL", default_database_url),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Stable test-only key for the Cloak vault.
config :camelot, Camelot.Vault,
  ciphers: [
    default:
      {Cloak.Ciphers.AES.GCM,
       tag: "AES.GCM.V1", key: Base.decode64!("J7yu5Cc7+9pBfgM5cBl4emV7DLAhsmO9Hzfo0r/qmTw="), iv_length: 12}
  ]

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :camelot, CamelotWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "TPCuyoJrndnkht+K1E840sCK+Xh1BldDo/sOD3MezPFCmmY9/ypz0AjJ6RUEvy/u",
  server: false

# Disable Oban job execution in tests
config :camelot, Oban, testing: :manual

# Reconciler queries the DB; disable its auto-tick in tests so the
# sandbox doesn't see an unowned querier.
config :camelot, :reconciler, autostart: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false
