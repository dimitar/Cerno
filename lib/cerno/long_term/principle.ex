defmodule Cerno.LongTerm.Principle do
  @moduledoc """
  Ecto schema for the `principles` table.

  A Principle is a ranked, linked, distilled knowledge unit in the long-term
  memory layer. Derived from one or more Insights via the organisation process.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @categories ~w(learning principle moral heuristic anti_pattern)a
  @statuses ~w(active decaying pruned)a

  schema "principles" do
    field :content, :string
    field :elaboration, :string
    field :content_hash, :string
    field :embedding, Pgvector.Ecto.Vector
    field :category, Ecto.Enum, values: @categories
    field :tags, {:array, :string}, default: []
    field :domains, {:array, :string}, default: []
    field :confidence, :float, default: 0.5
    field :frequency, :integer, default: 1
    field :recency_score, :float, default: 1.0
    field :source_quality, :float, default: 0.5
    field :rank, :float, default: 0.0
    field :status, Ecto.Enum, values: @statuses, default: :active

    has_many :derivations, Cerno.LongTerm.Derivation
    has_many :links_as_source, Cerno.LongTerm.PrincipleLink, foreign_key: :source_id
    has_many :links_as_target, Cerno.LongTerm.PrincipleLink, foreign_key: :target_id

    timestamps(type: :utc_datetime)
  end

  def changeset(principle, attrs) do
    principle
    |> cast(attrs, [
      :content,
      :elaboration,
      :content_hash,
      :embedding,
      :category,
      :tags,
      :domains,
      :confidence,
      :frequency,
      :recency_score,
      :source_quality,
      :rank,
      :status
    ])
    |> validate_required([:content, :content_hash])
    |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:rank, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_inclusion(:category, @categories)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:content_hash)
  end

  @doc """
  Compute composite rank score.

  rank = confidence(35%) + frequency(25%) + recency(20%) + quality(15%) + links(5%)
  """
  @spec compute_rank(map(), non_neg_integer()) :: float()
  def compute_rank(principle, link_count \\ 0) do
    config = Application.get_env(:cerno, :ranking, [])
    cw = Keyword.get(config, :confidence_weight, 0.35)
    fw = Keyword.get(config, :frequency_weight, 0.25)
    rw = Keyword.get(config, :recency_weight, 0.20)
    qw = Keyword.get(config, :quality_weight, 0.15)
    lw = Keyword.get(config, :links_weight, 0.05)

    # Normalize frequency to 0-1 using log scale (caps at ~150 observations)
    freq_normalized = :math.log(1 + principle.frequency) / :math.log(150)
    freq_normalized = min(freq_normalized, 1.0)

    # Normalize link count (caps at ~20 links)
    link_normalized = min(link_count / 20, 1.0)

    cw * principle.confidence +
      fw * freq_normalized +
      rw * principle.recency_score +
      qw * principle.source_quality +
      lw * link_normalized
  end
end
