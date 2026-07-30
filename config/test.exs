import Config

# Faster bcrypt for tests
config :bcrypt_elixir, log_rounds: 1

# In test we don't send emails
config :camelot, Camelot.Mailer, adapter: Swoosh.Adapters.Test

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :camelot, Camelot.Repo,
  username: System.get_env("DATABASE_USER", "postgres"),
  password: System.get_env("DATABASE_PASSWORD", "postgres"),
  hostname: System.get_env("DATABASE_HOST", "localhost"),
  port: String.to_integer(System.get_env("DATABASE_PORT", "5432")),
  database: "camelot_test#{System.get_env("MIX_TEST_PARTITION")}",
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

# Keep PostHog "enabled" so its sender pool starts (required for
# PostHog.Test to record captured events), but test_mode: true means
# events are kept in memory instead of sent over HTTP.
config :posthog,
  enable: true,
  api_key: "test-api-key",
  test_mode: true

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false
