import Config

config :cerno,
  ecto_repos: [Cerno.Repo]

# Embedding configuration
config :cerno, :embedding,
  provider: Cerno.Embedding.OpenAI,
  dimension: 1536

# Dedup thresholds
config :cerno, :dedup,
  exact_match: :content_hash,
  semantic_threshold: 0.92,
  cluster_threshold: 0.88,
  contradiction_range: {0.5, 0.85}

# Ranking weights
config :cerno, :ranking,
  confidence_weight: 0.35,
  frequency_weight: 0.25,
  recency_weight: 0.20,
  quality_weight: 0.15,
  links_weight: 0.05

# Decay settings
config :cerno, :decay,
  half_life_days: 90,
  prune_threshold: 0.10,
  decay_threshold: 0.15,
  stale_days_decay: 90,
  stale_days_prune: 180

# Promotion criteria (Reconciler → Organiser threshold)
config :cerno, :promotion,
  min_confidence: 0.7,
  min_observations: 3,
  min_age_days: 7

# Resolution settings
config :cerno, :resolution,
  semantic_weight: 0.5,
  rank_weight: 0.3,
  domain_weight: 0.2,
  min_hybrid_score: 0.3,
  max_principles: 20,
  already_represented_threshold: 0.85

# Phoenix PubSub
config :cerno, Cerno.PubSub,
  adapter: Phoenix.PubSub.PG2

# JSON library
config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
