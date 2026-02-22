defmodule Cerno.LongTerm.PrincipleLink do
  @moduledoc """
  Ecto schema for the `principle_links` table.

  Typed, weighted relationships between Principles. Supports
  relationship types: reinforces, generalizes, specializes,
  contradicts, depends_on, related.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @link_types ~w(reinforces generalizes specializes contradicts depends_on related)a

  schema "principle_links" do
    belongs_to :source, Cerno.LongTerm.Principle
    belongs_to :target, Cerno.LongTerm.Principle
    field :link_type, Ecto.Enum, values: @link_types
    field :strength, :float, default: 0.5

    timestamps(type: :utc_datetime)
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [:source_id, :target_id, :link_type, :strength])
    |> validate_required([:source_id, :target_id, :link_type])
    |> validate_number(:strength, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> foreign_key_constraint(:source_id)
    |> foreign_key_constraint(:target_id)
    |> unique_constraint([:source_id, :target_id, :link_type])
  end
end
