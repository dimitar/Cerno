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
  alias Cerno.LLM.ClaudeCli
  alias Cerno.Embedding.Pool, as: EmbeddingPool
  alias Cerno.{AccumulationRun, WatchedProject, Repo}

  @cooldown_ms 30_000

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
    {:ok, %{processing: MapSet.new(), last_processed: %{}}}
  end

  @impl true
  def handle_cast({:accumulate, path}, state) do
    now = System.monotonic_time(:millisecond)

    cond do
      MapSet.member?(state.processing, path) ->
        Logger.debug("Already processing #{path}, skipping")
        {:noreply, state}

      within_cooldown?(state.last_processed, path, now) ->
        Logger.debug("Path #{path} within cooldown, skipping")
        {:noreply, state}

      true ->
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
    now = System.monotonic_time(:millisecond)

    state = %{
      state
      | processing: MapSet.delete(state.processing, path),
        last_processed: Map.put(state.last_processed, path, now)
    }

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

  defp within_cooldown?(last_processed, path, now) do
    case Map.get(last_processed, path) do
      nil -> false
      last_time -> now - last_time < @cooldown_ms
    end
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
            learnings = distill_fragments(path, fragments)
            stats = ingest_learnings(learnings, fragments)

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

  # --- LLM distillation (file-level) ---

  defp distill_fragments(path, fragments) do
    if claude_md_source?(path) do
      case ClaudeCli.evaluate_file(fragments) do
        {:ok, learnings} ->
          Logger.info("LLM extracted #{length(learnings)} learnings from #{path}")
          learnings

        {:error, reason} ->
          Logger.warning("LLM distillation failed (#{inspect(reason)}), falling back to heuristic")
          heuristic_learnings(fragments)
      end
    else
      heuristic_learnings(fragments)
    end
  end

  defp heuristic_learnings(fragments) do
    Enum.map(fragments, fn fragment ->
      classification = Classifier.classify(fragment)

      %{
        content: fragment.content,
        category: classification.category,
        tags: classification.tags,
        domain: classification.domain,
        source_sections: if(fragment.section_heading, do: [fragment.section_heading], else: [])
      }
    end)
  end

  defp claude_md_source?(path) when is_binary(path) do
    basename = Path.basename(path) |> String.downcase()
    basename == "claude.md"
  end

  defp claude_md_source?(_), do: false

  # --- Ingestion ---

  defp ingest_learnings(learnings, fragments) do
    # Build a lookup from section heading to fragment for InsightSource linking
    fragment_lookup =
      fragments
      |> Enum.map(fn f -> {f.section_heading, f} end)
      |> Enum.into(%{})

    first_fragment = List.first(fragments)

    Enum.reduce(learnings, %{insights_created: 0, insights_updated: 0}, fn learning, stats ->
      source_fragment = find_source_fragment(learning, fragment_lookup, first_fragment)

      case ingest_learning(learning, source_fragment) do
        :created -> %{stats | insights_created: stats.insights_created + 1}
        :updated -> %{stats | insights_updated: stats.insights_updated + 1}
        :error -> stats
      end
    end)
  end

  defp find_source_fragment(learning, fragment_lookup, fallback) do
    source_sections = Map.get(learning, :source_sections, [])

    Enum.find_value(source_sections, fallback, fn heading ->
      Map.get(fragment_lookup, heading)
    end)
  end

  defp ingest_learning(learning, fragment) do
    content = learning.content
    content_hash = Insight.hash_content(content)

    case Repo.get_by(Insight, content_hash: content_hash) do
      nil ->
        case get_embedding(content) do
          {:ok, embedding} ->
            case find_semantic_match(embedding) do
              {:match, existing} ->
                merge_into_existing(existing, fragment, embedding)
                :updated

              :no_match ->
                insert_insight(fragment, content_hash, embedding, learning)
            end

          {:error, reason} ->
            Logger.warning("Embedding failed: #{inspect(reason)}, creating without embedding")
            insert_insight(fragment, content_hash, nil, learning)
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

  defp insert_insight(fragment, content_hash, embedding, learning) do
    now = DateTime.utc_now()

    attrs = %{
      content: learning.content,
      content_hash: content_hash,
      embedding: embedding,
      category: learning.category,
      tags: learning.tags,
      domain: learning.domain,
      confidence: 0.5,
      observation_count: 1,
      first_seen_at: now,
      last_seen_at: now,
      status: :active
    }

    case %Insight{} |> Insight.changeset(attrs) |> Repo.insert() do
      {:ok, insight} ->
        create_source(insight, fragment)

        # Check for contradictions
        if embedding, do: check_contradictions(insight, embedding)

        Logger.debug("Created insight #{insight.id} [#{learning.category}]")
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
