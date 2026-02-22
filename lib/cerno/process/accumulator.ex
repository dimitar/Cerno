defmodule Cerno.Process.Accumulator do
  @moduledoc """
  GenServer that drives the accumulation pipeline.

  Accumulation flow:
  1. Discovery — scan project paths for CLAUDE.md files, compare file hashes
  2. Parsing — split by H2 headings into Fragments
  3. Exact dedup — content_hash match → update counts
  4. Semantic dedup — embedding similarity > threshold → merge
  5. New insight creation — classify, tag, embed
  6. Contradiction check — detect conflicting insights

  Subscribes to `file:changed` events via PubSub and serializes
  processing per-project to avoid race conditions.
  """

  use GenServer
  require Logger

  alias Cerno.Atomic.Parser
  alias Cerno.ShortTerm.{Insight, InsightSource}
  alias Cerno.Repo

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Trigger accumulation for a specific project path."
  @spec accumulate(String.t()) :: :ok
  def accumulate(path) do
    GenServer.cast(__MODULE__, {:accumulate, path})
  end

  @doc "Trigger a full scan of all watched projects."
  @spec scan_all() :: :ok
  def scan_all do
    GenServer.cast(__MODULE__, :scan_all)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(Cerno.PubSub, "file:changed")
    {:ok, %{processing: MapSet.new()}}
  end

  @impl true
  def handle_cast({:accumulate, path}, state) do
    if MapSet.member?(state.processing, path) do
      Logger.debug("Already processing #{path}, skipping")
      {:noreply, state}
    else
      state = %{state | processing: MapSet.put(state.processing, path)}

      Task.Supervisor.start_child(Cerno.Process.TaskSupervisor, fn ->
        run_accumulation(path)
        GenServer.cast(__MODULE__, {:done, path})
      end)

      {:noreply, state}
    end
  end

  @impl true
  def handle_cast(:scan_all, state) do
    projects = Repo.all(Cerno.WatchedProject)

    Enum.each(projects, fn project ->
      accumulate(project.path)
    end)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:done, path}, state) do
    state = %{state | processing: MapSet.delete(state.processing, path)}

    Phoenix.PubSub.broadcast(
      Cerno.PubSub,
      "accumulation:complete",
      {:accumulation_complete, path}
    )

    {:noreply, state}
  end

  @impl true
  def handle_info({:file_changed, path}, state) do
    accumulate(path)
    {:noreply, state}
  end

  defp run_accumulation(path) do
    Logger.info("Starting accumulation for #{path}")

    case Parser.parse(path) do
      {:ok, fragments} ->
        Enum.each(fragments, &ingest_fragment/1)
        Logger.info("Accumulated #{length(fragments)} fragments from #{path}")

      {:error, reason} ->
        Logger.error("Failed to parse #{path}: #{inspect(reason)}")
    end
  end

  defp ingest_fragment(fragment) do
    content_hash = Insight.hash_content(fragment.content)

    case Repo.get_by(Insight, content_hash: content_hash) do
      nil ->
        create_new_insight(fragment, content_hash)

      existing ->
        update_existing_insight(existing, fragment)
    end
  end

  defp create_new_insight(fragment, content_hash) do
    now = DateTime.utc_now()

    attrs = %{
      content: fragment.content,
      content_hash: content_hash,
      observation_count: 1,
      first_seen_at: now,
      last_seen_at: now,
      status: :active
    }

    case %Insight{} |> Insight.changeset(attrs) |> Repo.insert() do
      {:ok, insight} ->
        create_source(insight, fragment)
        Logger.debug("Created new insight #{insight.id}")

      {:error, changeset} ->
        Logger.error("Failed to create insight: #{inspect(changeset.errors)}")
    end
  end

  defp update_existing_insight(insight, fragment) do
    insight
    |> Insight.changeset(%{
      observation_count: insight.observation_count + 1,
      last_seen_at: DateTime.utc_now()
    })
    |> Repo.update()

    create_source(insight, fragment)
  end

  defp create_source(insight, fragment) do
    {line_start, line_end} = fragment.line_range || {0, 0}

    attrs = %{
      insight_id: insight.id,
      fragment_id: fragment.id,
      source_path: fragment.source_path,
      source_project: fragment.source_project,
      section_heading: fragment.section_heading,
      line_range_start: line_start,
      line_range_end: line_end,
      file_hash: fragment.file_hash
    }

    case %InsightSource{} |> InsightSource.changeset(attrs) |> Repo.insert() do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end
  end
end
