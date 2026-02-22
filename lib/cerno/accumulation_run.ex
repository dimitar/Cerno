defmodule Cerno.AccumulationRun do
  @moduledoc """
  Ecto schema for the `accumulation_runs` table.

  Audit log for each accumulation scan. Tracks what was found,
  created, updated, and any errors encountered.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(running completed failed)

  schema "accumulation_runs" do
    field :project_path, :string
    field :status, :string, default: "running"
    field :fragments_found, :integer, default: 0
    field :insights_created, :integer, default: 0
    field :insights_updated, :integer, default: 0
    field :errors, {:array, :string}, default: []
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :project_path,
      :status,
      :fragments_found,
      :insights_created,
      :insights_updated,
      :errors,
      :started_at,
      :completed_at
    ])
    |> validate_required([:project_path])
    |> validate_inclusion(:status, @statuses)
  end

  @doc "Create a new run record at the start of accumulation."
  @spec start(String.t()) :: {:ok, %__MODULE__{}} | {:error, Ecto.Changeset.t()}
  def start(project_path) do
    %__MODULE__{}
    |> changeset(%{project_path: project_path, started_at: DateTime.utc_now()})
    |> Cerno.Repo.insert()
  end

  @doc "Mark a run as completed with final counts."
  @spec complete(%__MODULE__{}, map()) :: {:ok, %__MODULE__{}} | {:error, Ecto.Changeset.t()}
  def complete(run, stats) do
    run
    |> changeset(
      Map.merge(stats, %{
        status: "completed",
        completed_at: DateTime.utc_now()
      })
    )
    |> Cerno.Repo.update()
  end

  @doc "Mark a run as failed with error message."
  @spec fail(%__MODULE__{}, String.t()) :: {:ok, %__MODULE__{}} | {:error, Ecto.Changeset.t()}
  def fail(run, error) do
    run
    |> changeset(%{
      status: "failed",
      errors: [error | run.errors],
      completed_at: DateTime.utc_now()
    })
    |> Cerno.Repo.update()
  end
end
