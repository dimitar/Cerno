import Config

config :cerno, Cerno.Repo,
  username: "postgres",
  password: "super",
  hostname: "localhost",
  database: "cerno_test#{System.get_env("MIX_TEST_PARTITION")}",
  types: Cerno.PostgrexTypes,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :cerno, :embedding,
  provider: Cerno.Embedding.Mock,
  dimension: 1536

# Relaxed promotion criteria for tests
config :cerno, :promotion,
  min_confidence: 0.5,
  min_observations: 1,
  min_age_days: 0

config :logger, level: :warning
