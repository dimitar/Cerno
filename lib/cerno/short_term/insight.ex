defmodule Cerno.ShortTerm.Insight do
  @moduledoc """
  Ecto schema for the `insights` table.

  An Insight is a deduplicated, tagged, contradiction-aware knowledge unit
  in the short-term memory layer. Created by accumulating Fragments from
  CLAUDE.md files across projects.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  @categories ~w(convention principle technique warning preference fact pattern)a
  @statuses ~w(active contradicted superseded pending_review)a

  schema "insights" do
    field :content, :string
    field :content_hash, :string
    field :embedding, Pgvector.Ecto.Vector
    field :category, Ecto.Enum, values: @categories
    field :tags, {:array, :string}, default: []
    field :domain, :string
    field :confidence, :float, default: 0.5
    field :observation_count, :integer, default: 1
    field :first_seen_at, :utc_datetime
    field :last_seen_at, :utc_datetime
    field :status, Ecto.Enum, values: @statuses, default: :active

    has_many :sources, Cerno.ShortTerm.InsightSource
    has_many :contradictions_as_first, Cerno.ShortTerm.Contradiction, foreign_key: :insight_a_id
    has_many :contradictions_as_second, Cerno.ShortTerm.Contradiction, foreign_key: :insight_b_id

    many_to_many :clusters, Cerno.ShortTerm.Cluster,
      join_through: "cluster_insights",
      on_replace: :delete

    timestamps(type: :utc_datetime)
  end

  def changeset(insight, attrs) do
    insight
    |> cast(attrs, [
      :content,
      :content_hash,
      :embedding,
      :category,
      :tags,
      :domain,
      :confidence,
      :observation_count,
      :first_seen_at,
      :last_seen_at,
      :status
    ])
    |> validate_required([:content, :content_hash])
    |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_inclusion(:category, @categories)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:content_hash)
  end

  @doc "Compute SHA-256 hash of content for exact deduplication."
  @spec hash_content(String.t()) :: String.t()
  def hash_content(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end

  @doc """
  Find insights with embeddings similar to the given vector.

  Uses pgvector's cosine distance operator (`<=>`).
  Returns `[{insight, similarity}]` ordered by similarity descending.

  Options:
  - `:threshold` — minimum cosine similarity (default: 0.92)
  - `:limit` — max results (default: 10)
  - `:exclude_id` — insight ID to exclude from results
  - `:status` — only match insights with this status (default: :active)
  """
  @spec find_similar(Pgvector.Ecto.Vector.t() | [float()], keyword()) :: [{%__MODULE__{}, float()}]
  def find_similar(embedding, opts \\ []) do
    threshold = Keyword.get(opts, :threshold, 0.92)
    limit = Keyword.get(opts, :limit, 10)
    exclude_id = Keyword.get(opts, :exclude_id, nil)
    status = Keyword.get(opts, :status, :active)

    embedding_literal = Pgvector.new(embedding)

    query =
      from(i in __MODULE__,
        where: not is_nil(i.embedding),
        where: i.status == ^status,
        select: {i, fragment("1 - (? <=> ?)", i.embedding, ^embedding_literal)},
        order_by: fragment("? <=> ?", i.embedding, ^embedding_literal),
        limit: ^limit
      )

    query =
      if exclude_id do
        from([i] in query, where: i.id != ^exclude_id)
      else
        query
      end

    Cerno.Repo.all(query)
    |> Enum.filter(fn {_insight, similarity} -> similarity >= threshold end)
  end

  @doc """
  Find insights in the contradiction similarity range.

  Returns insights that are similar enough to be related but different enough
  to potentially contradict. Default range: 0.5–0.85.
  """
  @spec find_contradictions(Pgvector.Ecto.Vector.t() | [float()], keyword()) :: [{%__MODULE__{}, float()}]
  def find_contradictions(embedding, opts \\ []) do
    config = Application.get_env(:cerno, :dedup, [])
    {low, high} = Keyword.get(config, :contradiction_range, {0.5, 0.85})
    exclude_id = Keyword.get(opts, :exclude_id, nil)

    find_similar(embedding,
      threshold: low,
      limit: 20,
      exclude_id: exclude_id
    )
    |> Enum.filter(fn {_insight, similarity} -> similarity <= high end)
  end
end
