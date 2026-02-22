defmodule Cerno.WatchedProject do
  @moduledoc """
  Ecto schema for the `watched_projects` table.

  Tracks projects that Cerno monitors for CLAUDE.md changes.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "watched_projects" do
    field :name, :string
    field :path, :string
    field :last_scanned_at, :utc_datetime
    field :file_hash, :string
    field :active, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  def changeset(project, attrs) do
    project
    |> cast(attrs, [:name, :path, :last_scanned_at, :file_hash, :active])
    |> validate_required([:name, :path])
    |> unique_constraint(:path)
  end
end
