defmodule Cerno.Repo.Migrations.ResizeVectorColumns do
  use Ecto.Migration

  @doc """
  Resize vector columns to support different embedding providers.

  OpenAI text-embedding-3-small: 1536 dimensions
  Ollama nomic-embed-text: 768 dimensions

  pgvector allows changing column size via ALTER COLUMN. Existing data
  with a different dimension will cause an error — run this migration
  on a fresh DB or after clearing embeddings.
  """

  def up do
    dim = Application.get_env(:cerno, :embedding)[:dimension] || 768

    # Drop HNSW indexes first (they depend on column type)
    execute "DROP INDEX IF EXISTS insights_embedding_index"
    execute "DROP INDEX IF EXISTS principles_embedding_index"

    # Resize vector columns
    execute "ALTER TABLE insights ALTER COLUMN embedding TYPE vector(#{dim})"
    execute "ALTER TABLE clusters ALTER COLUMN centroid TYPE vector(#{dim})"
    execute "ALTER TABLE principles ALTER COLUMN embedding TYPE vector(#{dim})"

    # Recreate HNSW indexes
    execute """
    CREATE INDEX insights_embedding_index ON insights
    USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64)
    """

    execute """
    CREATE INDEX principles_embedding_index ON principles
    USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64)
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS insights_embedding_index"
    execute "DROP INDEX IF EXISTS principles_embedding_index"

    execute "ALTER TABLE insights ALTER COLUMN embedding TYPE vector(1536)"
    execute "ALTER TABLE clusters ALTER COLUMN centroid TYPE vector(1536)"
    execute "ALTER TABLE principles ALTER COLUMN embedding TYPE vector(1536)"

    execute """
    CREATE INDEX insights_embedding_index ON insights
    USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64)
    """

    execute """
    CREATE INDEX principles_embedding_index ON principles
    USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64)
    """
  end
end
