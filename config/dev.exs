import Config

config :cerno, Cerno.Repo,
  username: "postgres",
  password: "super",
  hostname: "localhost",
  database: "cerno_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :cerno, Cerno.API.Endpoint,
  http: [port: 4000],
  debug_errors: true

config :logger, :console, format: "[$level] $message\n"
