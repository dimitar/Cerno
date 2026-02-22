defmodule Cerno.ShortTerm.Contradiction do
  @moduledoc """
  Ecto schema for the `contradictions` table.

  A first-class entity representing a detected contradiction between two
  Insights. Has a resolution lifecycle: unresolved → resolved, with
  different contradiction types (direct, partial, contextual).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @contradiction_types ~w(direct partial contextual)a

  @negation_pairs [
    {"always", "never"},
    {"do", "don't"},
    {"use", "avoid"},
    {"should", "should not"},
    {"prefer", "avoid"},
    {"must", "must not"},
    {"enable", "disable"}
  ]

  @doc """
  Check whether two content strings contain a negation pattern.

  Returns `true` if one string contains a word from a negation pair and the
  other contains its opposite (e.g. "always" ↔ "never", "use" ↔ "avoid").
  """
  @spec has_negation?(String.t(), String.t()) :: boolean()
  def has_negation?(content_a, content_b) do
    a_lower = String.downcase(content_a)
    b_lower = String.downcase(content_b)

    Enum.any?(@negation_pairs, fn {pos, neg} ->
      (String.contains?(a_lower, pos) and String.contains?(b_lower, neg)) or
        (String.contains?(a_lower, neg) and String.contains?(b_lower, pos))
    end)
  end
  @resolution_statuses ~w(unresolved resolved dismissed)a

  schema "contradictions" do
    belongs_to :insight_a, Cerno.ShortTerm.Insight
    belongs_to :insight_b, Cerno.ShortTerm.Insight
    field :contradiction_type, Ecto.Enum, values: @contradiction_types
    field :description, :string
    field :resolution_status, Ecto.Enum, values: @resolution_statuses, default: :unresolved
    field :resolution_notes, :string
    field :detected_by, :string
    field :similarity_score, :float

    timestamps(type: :utc_datetime)
  end

  def changeset(contradiction, attrs) do
    contradiction
    |> cast(attrs, [
      :insight_a_id,
      :insight_b_id,
      :contradiction_type,
      :description,
      :resolution_status,
      :resolution_notes,
      :detected_by,
      :similarity_score
    ])
    |> validate_required([:insight_a_id, :insight_b_id, :contradiction_type])
    |> validate_number(:similarity_score,
      greater_than_or_equal_to: 0.0,
      less_than_or_equal_to: 1.0
    )
    |> foreign_key_constraint(:insight_a_id)
    |> foreign_key_constraint(:insight_b_id)
    |> unique_constraint([:insight_a_id, :insight_b_id],
      name: :contradictions_unique_pair_index
    )
  end
end
