defmodule Cerno.ShortTerm.Cluster do
  @moduledoc """
  Ecto schema for the `clusters` table.

  Semantic groupings of related Insights. Each cluster has a centroid
  embedding and a coherence score indicating how tightly related
  the member insights are.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "clusters" do
    field :name, :string
    field :description, :string
    field :centroid, Pgvector.Ecto.Vector
    field :coherence_score, :float
    field :insight_count, :integer, default: 0

    many_to_many :insights, Cerno.ShortTerm.Insight,
      join_through: "cluster_insights",
      on_replace: :delete

    timestamps(type: :utc_datetime)
  end

  def changeset(cluster, attrs) do
    cluster
    |> cast(attrs, [:name, :description, :centroid, :coherence_score, :insight_count])
    |> validate_number(:coherence_score,
      greater_than_or_equal_to: 0.0,
      less_than_or_equal_to: 1.0
    )
  end
end
