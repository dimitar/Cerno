defmodule Cerno.ShortTerm.InsightSource do
  @moduledoc """
  Ecto schema for the `insight_sources` table.

  Traces an Insight back to its original source — which file, project,
  line range, and fragment contributed to this insight. Enables full
  provenance tracking for the accumulation pipeline.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "insight_sources" do
    belongs_to :insight, Cerno.ShortTerm.Insight
    field :fragment_id, :string
    field :source_path, :string
    field :source_project, :string
    field :section_heading, :string
    field :line_range_start, :integer
    field :line_range_end, :integer
    field :file_hash, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(source, attrs) do
    source
    |> cast(attrs, [
      :insight_id,
      :fragment_id,
      :source_path,
      :source_project,
      :section_heading,
      :line_range_start,
      :line_range_end,
      :file_hash
    ])
    |> validate_required([:insight_id, :fragment_id, :source_path, :source_project])
    |> unique_constraint(:fragment_id)
    |> foreign_key_constraint(:insight_id)
  end
end
