defmodule Cerno.Process.Accumulator do
  @moduledoc """
  GenServer that drives the accumulation pipeline.

  Accumulation flow:
  1. Discovery — scan project path, compare file hash, skip unchanged
  2. Parsing — split into Fragments via pluggable parser
  3. Exact dedup — content_hash match → update counts, add source
  4. Semantic dedup — embedding similarity > threshold → merge into existing
  5. New insight — create with embedding, classify category/tags/domain
  6. Contradiction check — flag insights in similarity range 0.5–0.85

  Subscribes to `file:changed` events via PubSub and serializes
  processing per-project to avoid race conditions.
  """

  use GenServer
  require Logger

  alias Cerno.Atomic.Parser
  alias Cerno.ShortTerm.{Insight, InsightSource, Contradiction, Classifier}
  alias Cerno.Embedding.Pool, as: EmbeddingPool
  alias Cerno.{AccumulationRun, WatchedProject, Repo}

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
        try do
          run_accumulation(path)
        rescue
          e -> Logger.error("Accumulation failed for #{path}: #{inspect(e)}")
        after
          GenServer.cast(__MODULE__, {:done, path})
        end
      end)

      {:noreply, state}
    end
  end

  @impl true
  def handle_cast(:scan_all, state) do
    import Ecto.Query
    projects = Repo.all(from(w in WatchedProject, where: w.active == true))

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

  # --- Accumulation pipeline ---

  defp run_accumulation(path) do
    Logger.info("Starting accumulation for #{path}")

    {:ok, run} = AccumulationRun.start(path)

    case check_file_changed(path) do
      :unchanged ->
        Logger.info("File unchanged, skipping #{path}")
        AccumulationRun.complete(run, %{fragments_found: 0})

      {:changed, file_hash} ->
        case Parser.parse(path) do
          {:ok, fragments} ->
            stats = ingest_fragments(fragments)

            update_watched_project(path, file_hash)
            AccumulationRun.complete(run, Map.put(stats, :fragments_found, length(fragments)))

            Logger.info(
              "Accumulated #{length(fragments)} fragments from #{path} " <>
                "(#{stats.insights_created} new, #{stats.insights_updated} updated)"
            )

          {:error, reason} ->
            Logger.error("Failed to parse #{path}: #{inspect(reason)}")
            AccumulationRun.fail(run, inspect(reason))
        end
    end
  end

  defp check_file_changed(path) do
    import Ecto.Query

    case File.read(path) do
      {:ok, content} ->
        current_hash = Parser.hash_file(content)

        stored_hash =
          Repo.one(from(w in WatchedProject, where: w.path == ^path, select: w.file_hash))

        if stored_hash == current_hash do
          :unchanged
        else
          {:changed, current_hash}
        end

      {:error, _} ->
        {:changed, nil}
    end
  end

  defp update_watched_project(path, file_hash) do
    import Ecto.Query

    case Repo.one(from(w in WatchedProject, where: w.path == ^path)) do
      nil ->
        :ok

      project ->
        project
        |> WatchedProject.changeset(%{file_hash: file_hash, last_scanned_at: DateTime.utc_now()})
        |> Repo.update()
    end
  end

  defp ingest_fragments(fragments) do
    Enum.reduce(fragments, %{insights_created: 0, insights_updated: 0}, fn fragment, stats ->
      case ingest_fragment(fragment) do
        :created -> %{stats | insights_created: stats.insights_created + 1}
        :updated -> %{stats | insights_updated: stats.insights_updated + 1}
        :error -> stats
      end
    end)
  end

  defp ingest_fragment(fragment) do
    content_hash = Insight.hash_content(fragment.content)

    # Step 1: Exact dedup by content hash
    case Repo.get_by(Insight, content_hash: content_hash) do
      nil ->
        # Step 2: Try to get embedding
        case get_embedding(fragment.content) do
          {:ok, embedding} ->
            # Step 3: Semantic dedup
            case find_semantic_match(embedding) do
              {:match, existing} ->
                merge_into_existing(existing, fragment, embedding)
                :updated

              :no_match ->
                # Step 4: Create new insight with classification
                create_new_insight(fragment, content_hash, embedding)
            end

          {:error, reason} ->
            # Create without embedding (embedding service may be down)
            Logger.warning("Embedding failed: #{inspect(reason)}, creating without embedding")
            create_new_insight(fragment, content_hash, nil)
        end

      existing ->
        update_existing_insight(existing, fragment)
        :updated
    end
  end

  defp get_embedding(content) do
    EmbeddingPool.get_embedding(content)
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp find_semantic_match(embedding) do
    config = Application.get_env(:cerno, :dedup, [])
    threshold = Keyword.get(config, :semantic_threshold, 0.92)

    case Insight.find_similar(embedding, threshold: threshold, limit: 1) do
      [{existing, _similarity}] -> {:match, existing}
      [] -> :no_match
    end
  end

  defp merge_into_existing(existing, fragment, _embedding) do
    Logger.debug("Semantic match found for fragment, merging into insight #{existing.id}")

    existing
    |> Insight.changeset(%{
      observation_count: existing.observation_count + 1,
      last_seen_at: DateTime.utc_now()
    })
    |> Repo.update()

    create_source(existing, fragment)
  end

  defp create_new_insight(fragment, content_hash, embedding) do
    now = DateTime.utc_now()
    classification = Classifier.classify(fragment)

    attrs = %{
      content: fragment.content,
      content_hash: content_hash,
      embedding: embedding,
      category: classification.category,
      tags: classification.tags,
      domain: classification.domain,
      confidence: 0.5,
      observation_count: 1,
      first_seen_at: now,
      last_seen_at: now,
      status: :active
    }

    case %Insight{} |> Insight.changeset(attrs) |> Repo.insert() do
      {:ok, insight} ->
        create_source(insight, fragment)

        # Step 5: Check for contradictions
        if embedding, do: check_contradictions(insight, embedding)

        Logger.debug("Created insight #{insight.id} [#{classification.category}]")
        :created

      {:error, changeset} ->
        Logger.error("Failed to create insight: #{inspect(changeset.errors)}")
        :error
    end
  end

  defp update_existing_insight(existing, fragment) do
    existing
    |> Insight.changeset(%{
      observation_count: existing.observation_count + 1,
      last_seen_at: DateTime.utc_now()
    })
    |> Repo.update()

    create_source(existing, fragment)
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

  # --- Contradiction detection ---

  defp check_contradictions(insight, embedding) do
    candidates = Insight.find_contradictions(embedding, exclude_id: insight.id)

    created =
      candidates
      |> Enum.filter(fn {other, _similarity} ->
        Contradiction.has_negation?(insight.content, other.content)
      end)
      |> Enum.map(fn {other, similarity} ->
        create_contradiction(insight, other, similarity)
      end)
      |> Enum.count(&(&1 == :ok))

    if created > 0 do
      Logger.info(
        "Found #{created} contradiction(s) for insight #{insight.id}"
      )
    end
  end

  defp create_contradiction(insight_a, insight_b, similarity) do
    # Normalize order: lower ID first
    {first_id, second_id} =
      if insight_a.id < insight_b.id,
        do: {insight_a.id, insight_b.id},
        else: {insight_b.id, insight_a.id}

    attrs = %{
      insight_a_id: first_id,
      insight_b_id: second_id,
      contradiction_type: :direct,
      detected_by: "accumulator",
      similarity_score: similarity,
      description: "Direct contradiction detected via negation pattern (similarity: #{Float.round(similarity, 3)})"
    }

    case %Contradiction{} |> Contradiction.changeset(attrs) |> Repo.insert() do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end
  end
end
