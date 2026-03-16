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
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "camelot_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :camelot, CamelotWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "TPCuyoJrndnkht+K1E840sCK+Xh1BldDo/sOD3MezPFCmmY9/ypz0AjJ6RUEvy/u",
  server: false

# Disable Oban job execution in tests
config :camelot, Oban, testing: :manual

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
