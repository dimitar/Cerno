defmodule Cerno.ResolutionRun do
  @moduledoc """
  Ecto schema for the `resolution_runs` table.

  Audit log for each resolution operation. Tracks target path, agent type,
  how many principles were resolved, and conflicts detected.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(running completed failed)

  schema "resolution_runs" do
    field :target_path, :string
    field :agent_type, :string
    field :status, :string, default: "running"
    field :principles_resolved, :integer, default: 0
    field :conflicts_detected, :integer, default: 0
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :target_path,
      :agent_type,
      :status,
      :principles_resolved,
      :conflicts_detected,
      :started_at,
      :completed_at
    ])
    |> validate_required([:target_path])
    |> validate_inclusion(:status, @statuses)
  end

  @doc "Create a new run record at the start of resolution."
  @spec start(String.t(), String.t()) :: {:ok, %__MODULE__{}} | {:error, Ecto.Changeset.t()}
  def start(target_path, agent_type \\ "claude") do
    %__MODULE__{}
    |> changeset(%{target_path: target_path, agent_type: agent_type, started_at: DateTime.utc_now()})
    |> Cerno.Repo.insert()
  end

  @doc "Mark a run as completed with final stats."
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

  @doc "Mark a run as failed."
  @spec fail(%__MODULE__{}) :: {:ok, %__MODULE__{}} | {:error, Ecto.Changeset.t()}
  def fail(run) do
    run
    |> changeset(%{
      status: "failed",
      completed_at: DateTime.utc_now()
    })
    |> Cerno.Repo.update()
  end
end
