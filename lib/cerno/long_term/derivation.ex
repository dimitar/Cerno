defmodule Cerno.LongTerm.Derivation do
  @moduledoc """
  Ecto schema for the `derivations` table.

  Links a Principle to the Insights it was derived from, with a
  contribution weight indicating how much each insight contributed
  to the principle's formation. Enables full traceability from
  long-term back to short-term memory.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "derivations" do
    belongs_to :principle, Cerno.LongTerm.Principle
    belongs_to :insight, Cerno.ShortTerm.Insight
    field :contribution_weight, :float, default: 1.0

    timestamps(type: :utc_datetime)
  end

  def changeset(derivation, attrs) do
    derivation
    |> cast(attrs, [:principle_id, :insight_id, :contribution_weight])
    |> validate_required([:principle_id, :insight_id])
    |> validate_number(:contribution_weight,
      greater_than_or_equal_to: 0.0,
      less_than_or_equal_to: 1.0
    )
    |> foreign_key_constraint(:principle_id)
    |> foreign_key_constraint(:insight_id)
    |> unique_constraint([:principle_id, :insight_id])
  end
end
