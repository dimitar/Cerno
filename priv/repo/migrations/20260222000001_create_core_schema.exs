defmodule Cerno.Repo.Migrations.CreateCoreSchema do
  use Ecto.Migration

  def up do
    # Enable pgvector extension
    execute "CREATE EXTENSION IF NOT EXISTS vector"

    # --- Insights (Short-Term Memory) ---

    create table(:insights) do
      add :content, :text, null: false
      add :content_hash, :string, null: false
      add :embedding, :vector, size: 1536
      add :category, :string
      add :tags, {:array, :string}, default: []
      add :domain, :string
      add :confidence, :float, default: 0.5
      add :observation_count, :integer, default: 1
      add :first_seen_at, :utc_datetime
      add :last_seen_at, :utc_datetime
      add :status, :string, default: "active"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:insights, [:content_hash])
    create index(:insights, [:status])
    create index(:insights, [:category])
    create index(:insights, [:domain])
    create index(:insights, [:confidence])

    # GIN index on tags array
    execute "CREATE INDEX insights_tags_index ON insights USING GIN (tags)"

    # HNSW vector index for semantic search
    execute """
    CREATE INDEX insights_embedding_index ON insights
    USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64)
    """

    # --- Insight Sources ---

    create table(:insight_sources) do
      add :insight_id, references(:insights, on_delete: :delete_all), null: false
      add :fragment_id, :string, null: false
      add :source_path, :string, null: false
      add :source_project, :string, null: false
      add :section_heading, :string
      add :line_range_start, :integer
      add :line_range_end, :integer
      add :file_hash, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:insight_sources, [:fragment_id])
    create index(:insight_sources, [:insight_id])
    create index(:insight_sources, [:source_project])

    # --- Contradictions ---

    create table(:contradictions) do
      add :insight_a_id, references(:insights, on_delete: :delete_all), null: false
      add :insight_b_id, references(:insights, on_delete: :delete_all), null: false
      add :contradiction_type, :string, null: false
      add :description, :text
      add :resolution_status, :string, default: "unresolved"
      add :resolution_notes, :text
      add :detected_by, :string
      add :similarity_score, :float

      timestamps(type: :utc_datetime)
    end

    create index(:contradictions, [:insight_a_id])
    create index(:contradictions, [:insight_b_id])
    create index(:contradictions, [:resolution_status])

    # Unique constraint using LEAST/GREATEST to prevent (A,B)/(B,A) duplicates
    execute """
    CREATE UNIQUE INDEX contradictions_unique_pair_index
    ON contradictions (LEAST(insight_a_id, insight_b_id), GREATEST(insight_a_id, insight_b_id))
    """

    # --- Clusters ---

    create table(:clusters) do
      add :name, :string
      add :description, :text
      add :centroid, :vector, size: 1536
      add :coherence_score, :float
      add :insight_count, :integer, default: 0

      timestamps(type: :utc_datetime)
    end

    # --- Cluster-Insights join table ---

    create table(:cluster_insights, primary_key: false) do
      add :cluster_id, references(:clusters, on_delete: :delete_all), null: false
      add :insight_id, references(:insights, on_delete: :delete_all), null: false
    end

    create unique_index(:cluster_insights, [:cluster_id, :insight_id])
    create index(:cluster_insights, [:insight_id])

    # --- Principles (Long-Term Memory) ---

    create table(:principles) do
      add :content, :text, null: false
      add :elaboration, :text
      add :content_hash, :string, null: false
      add :embedding, :vector, size: 1536
      add :category, :string
      add :tags, {:array, :string}, default: []
      add :domains, {:array, :string}, default: []
      add :confidence, :float, default: 0.5
      add :frequency, :integer, default: 1
      add :recency_score, :float, default: 1.0
      add :source_quality, :float, default: 0.5
      add :rank, :float, default: 0.0
      add :status, :string, default: "active"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:principles, [:content_hash])
    create index(:principles, [:status])
    create index(:principles, [:rank])
    create index(:principles, [:category])

    # GIN indexes on array columns
    execute "CREATE INDEX principles_tags_index ON principles USING GIN (tags)"
    execute "CREATE INDEX principles_domains_index ON principles USING GIN (domains)"

    # HNSW vector index
    execute """
    CREATE INDEX principles_embedding_index ON principles
    USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64)
    """

    # --- Derivations ---

    create table(:derivations) do
      add :principle_id, references(:principles, on_delete: :delete_all), null: false
      add :insight_id, references(:insights, on_delete: :delete_all), null: false
      add :contribution_weight, :float, default: 1.0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:derivations, [:principle_id, :insight_id])
    create index(:derivations, [:insight_id])

    # --- Principle Links ---

    create table(:principle_links) do
      add :source_id, references(:principles, on_delete: :delete_all), null: false
      add :target_id, references(:principles, on_delete: :delete_all), null: false
      add :link_type, :string, null: false
      add :strength, :float, default: 0.5

      timestamps(type: :utc_datetime)
    end

    create unique_index(:principle_links, [:source_id, :target_id, :link_type])
    create index(:principle_links, [:target_id])

    # --- Watched Projects ---

    create table(:watched_projects) do
      add :name, :string, null: false
      add :path, :string, null: false
      add :last_scanned_at, :utc_datetime
      add :file_hash, :string
      add :active, :boolean, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:watched_projects, [:path])

    # --- Accumulation Runs ---

    create table(:accumulation_runs) do
      add :project_path, :string, null: false
      add :status, :string, default: "running"
      add :fragments_found, :integer, default: 0
      add :insights_created, :integer, default: 0
      add :insights_updated, :integer, default: 0
      add :errors, {:array, :string}, default: []
      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # --- Resolution Runs ---

    create table(:resolution_runs) do
      add :target_path, :string, null: false
      add :agent_type, :string
      add :status, :string, default: "running"
      add :principles_resolved, :integer, default: 0
      add :conflicts_detected, :integer, default: 0
      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # --- Embedding Model Config ---

    create table(:embedding_model_config) do
      add :provider, :string, null: false
      add :model_name, :string, null: false
      add :dimension, :integer, null: false
      add :active, :boolean, default: true
      add :activated_at, :utc_datetime
      add :deactivated_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end
  end

  def down do
    drop table(:embedding_model_config)
    drop table(:resolution_runs)
    drop table(:accumulation_runs)
    drop table(:watched_projects)
    drop table(:principle_links)
    drop table(:derivations)
    drop table(:cluster_insights)
    drop table(:clusters)
    drop table(:contradictions)
    drop table(:insight_sources)
    drop table(:principles)
    drop table(:insights)

    execute "DROP EXTENSION IF EXISTS vector"
  end
end
