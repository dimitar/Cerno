import Config

config :cerno, Cerno.Repo,
  username: "postgres",
  password: "super",
  hostname: "localhost",
  database: "cerno_dev",
  types: Cerno.PostgrexTypes,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :cerno, Cerno.API.Endpoint,
  http: [port: 4000],
  debug_errors: true

# Relaxed promotion criteria for dev/testing
config :cerno, :promotion,
  min_confidence: 0.3,
  min_observations: 1,
  min_age_days: 0

# Embedding: use Ollama locally (ollama pull nomic-embed-text)
config :cerno, :embedding,
  provider: Cerno.Embedding.Ollama,
  dimension: 768,
  ollama_url: "http://localhost:11434",
  ollama_model: "nomic-embed-text"

config :logger, :console, format: "[$level] $message\n"
