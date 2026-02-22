defmodule Cerno.ShortTerm.Insight do
  @moduledoc """
  Ecto schema for the `insights` table.

  An Insight is a deduplicated, tagged, contradiction-aware knowledge unit
  in the short-term memory layer. Created by accumulating Fragments from
  CLAUDE.md files across projects.
  """

  use Ecto.Schema
  import Ecto.Changeset

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
end
