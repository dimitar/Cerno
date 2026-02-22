import Config

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  config :cerno, Cerno.Repo,
    url: database_url,
    types: Cerno.PostgrexTypes,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")

  config :cerno, Cerno.API.Endpoint,
    http: [port: String.to_integer(System.get_env("PORT") || "4000")]
end

# OpenAI API key (all environments)
if api_key = System.get_env("OPENAI_API_KEY") do
  config :cerno, :embedding,
    api_key: api_key
end
