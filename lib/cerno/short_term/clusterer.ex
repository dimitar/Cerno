defmodule Cerno.ShortTerm.Clusterer do
  @moduledoc """
  Clustering engine for the short-term memory layer.

  Groups semantically related Insights into Clusters using connected-component
  analysis on an embedding similarity graph. Also handles intra-cluster
  deduplication and cross-cluster contradiction scanning.

  The pipeline:
  1. Build similarity graph from active insights (cosine similarity >= cluster_threshold)
  2. Find connected components via BFS
  3. Compute centroid and coherence for each component
  4. Persist clusters (full rebuild)
  5. Deduplicate within clusters (merge near-duplicates)
  6. Scan for cross-cluster contradictions
  """

  import Ecto.Query
  require Logger

  alias Cerno.Repo
  alias Cerno.ShortTerm.{Insight, Cluster, Contradiction}

  # --- Pure math ---

  @doc """
  Compute cosine similarity between two vectors.

  Returns a float in [-1, 1]. Returns 0.0 if either vector has zero norm.
  """
  @spec cosine_similarity([float()], [float()]) :: float()
  def cosine_similarity(vec_a, vec_b) when is_list(vec_a) and is_list(vec_b) do
    dot = dot_product(vec_a, vec_b)
    norm_a = norm(vec_a)
    norm_b = norm(vec_b)

    if norm_a == 0.0 or norm_b == 0.0 do
      0.0
    else
      dot / (norm_a * norm_b)
    end
  end

  defp dot_product(a, b) do
    a
    |> Enum.zip(b)
    |> Enum.reduce(0.0, fn {x, y}, acc -> acc + x * y end)
  end

  defp norm(vec) do
    vec
    |> Enum.reduce(0.0, fn x, acc -> acc + x * x end)
    |> :math.sqrt()
  end

  # --- Main clustering entry point ---

  @doc """
  Cluster all active insights by embedding similarity.

  Loads active insights with non-nil embeddings, builds a similarity graph
  at the configured cluster threshold, finds connected components, and
  computes centroid and coherence for each.

  Returns a list of cluster maps:

      [%{insight_ids: [id, ...], centroid: [float, ...], coherence: float}, ...]
  """
  @spec cluster_insights() :: [map()]
  def cluster_insights do
    config = Application.get_env(:cerno, :dedup, [])
    threshold = Keyword.get(config, :cluster_threshold, 0.88)

    # Load all active insights with embeddings
    insights =
      from(i in Insight,
        where: i.status == :active,
        where: not is_nil(i.embedding)
      )
      |> Repo.all()

    Logger.info("Clustering #{length(insights)} active insights at threshold #{threshold}")

    if insights == [] do
      []
    else
      # Build adjacency map: insight_id -> MapSet of neighbour ids
      adjacency = build_adjacency_map(insights, threshold)

      # Find connected components
      all_ids = Enum.map(insights, & &1.id)
      components = find_connected_components(all_ids, adjacency)

      # Build an id -> embedding lookup
      embedding_map =
        Map.new(insights, fn i -> {i.id, to_list(i.embedding)} end)

      # For each component, compute centroid and coherence
      Enum.map(components, fn component_ids ->
        embeddings = Enum.map(component_ids, &Map.fetch!(embedding_map, &1))
        centroid = compute_centroid(embeddings)
        coherence = compute_coherence(embeddings)

        %{
          insight_ids: component_ids,
          centroid: centroid,
          coherence: coherence
        }
      end)
    end
  end

  defp build_adjacency_map(insights, threshold) do
    # For each insight, find similar insights above threshold
    Enum.reduce(insights, %{}, fn insight, adj ->
      embedding = to_list(insight.embedding)

      neighbours =
        Insight.find_similar(embedding,
          threshold: threshold,
          limit: 100,
          exclude_id: insight.id,
          status: :active
        )

      neighbour_ids =
        neighbours
        |> Enum.map(fn {neighbour, _similarity} -> neighbour.id end)
        |> MapSet.new()

      # Merge into adjacency map (ensure symmetry)
      adj = Map.update(adj, insight.id, neighbour_ids, &MapSet.union(&1, neighbour_ids))

      Enum.reduce(neighbour_ids, adj, fn nid, inner_adj ->
        Map.update(inner_adj, nid, MapSet.new([insight.id]), &MapSet.put(&1, insight.id))
      end)
    end)
  end

  @doc """
  Find connected components in a graph via BFS.

  Takes a list of node IDs and an adjacency map (id -> MapSet of neighbour ids).
  Returns a list of lists, where each inner list is a connected component.
  """
  @spec find_connected_components([integer()], %{integer() => MapSet.t()}) :: [[integer()]]
  def find_connected_components(ids, adjacency) do
    {components, _visited} =
      Enum.reduce(ids, {[], MapSet.new()}, fn id, {comps, visited} ->
        if MapSet.member?(visited, id) do
          {comps, visited}
        else
          {component, visited} = bfs(id, adjacency, visited)
          {[component | comps], visited}
        end
      end)

    Enum.reverse(components)
  end

  defp bfs(start_id, adjacency, visited) do
    bfs_loop([start_id], adjacency, MapSet.put(visited, start_id), [start_id])
  end

  defp bfs_loop([], _adjacency, visited, component) do
    {Enum.reverse(component), visited}
  end

  defp bfs_loop([current | rest], adjacency, visited, component) do
    neighbours = Map.get(adjacency, current, MapSet.new())

    {new_queue, visited, component} =
      Enum.reduce(neighbours, {rest, visited, component}, fn nid, {q, v, c} ->
        if MapSet.member?(v, nid) do
          {q, v, c}
        else
          {q ++ [nid], MapSet.put(v, nid), [nid | c]}
        end
      end)

    bfs_loop(new_queue, adjacency, visited, component)
  end

  defp compute_centroid(embeddings) do
    count = length(embeddings)

    if count == 0 do
      []
    else
      dim = length(hd(embeddings))

      Enum.reduce(embeddings, List.duplicate(0.0, dim), fn emb, acc ->
        Enum.zip(acc, emb)
        |> Enum.map(fn {a, b} -> a + b end)
      end)
      |> Enum.map(&(&1 / count))
    end
  end

  defp compute_coherence(embeddings) when length(embeddings) <= 1, do: 1.0

  defp compute_coherence(embeddings) do
    pairs =
      for {a, i} <- Enum.with_index(embeddings),
          {b, j} <- Enum.with_index(embeddings),
          i < j,
          do: {a, b}

    if pairs == [] do
      1.0
    else
      total = Enum.reduce(pairs, 0.0, fn {a, b}, acc -> acc + cosine_similarity(a, b) end)
      total / length(pairs)
    end
  end

  # --- Persistence ---

  @doc """
  Persist cluster maps to the database (full rebuild).

  Deletes all existing clusters (cascades to cluster_insights join table),
  then inserts new clusters and join records within a transaction.

  Returns `{:ok, count}` with the number of clusters created.
  """
  @spec persist_clusters([map()]) :: {:ok, non_neg_integer()} | {:error, any()}
  def persist_clusters(cluster_maps) do
    Repo.transaction(fn ->
      # Full rebuild: delete all existing clusters (cascades to cluster_insights)
      Repo.delete_all(Cluster)

      count =
        Enum.reduce(cluster_maps, 0, fn cluster_map, acc ->
          {:ok, cluster} =
            %Cluster{}
            |> Cluster.changeset(%{
              centroid: cluster_map.centroid,
              coherence_score: cluster_map.coherence,
              insight_count: length(cluster_map.insight_ids),
              name: "cluster-#{acc + 1}",
              description: "Auto-generated cluster with #{length(cluster_map.insight_ids)} insights"
            })
            |> Repo.insert()

          # Insert join records
          entries =
            Enum.map(cluster_map.insight_ids, fn insight_id ->
              %{cluster_id: cluster.id, insight_id: insight_id}
            end)

          Repo.insert_all("cluster_insights", entries)

          acc + 1
        end)

      Logger.info("Persisted #{count} clusters")
      count
    end)
  end

  # --- Intra-cluster deduplication ---

  @doc """
  Deduplicate insights within each cluster.

  For each cluster, sorts insights by observation_count descending. Compares
  pairs: if cosine similarity >= threshold, the winner (higher observation count)
  absorbs the loser. Winner gains the loser's observation count and takes the
  max last_seen_at. Loser is marked as :superseded.

  Returns `{:ok, %{merged: count, superseded: count}}`.
  """
  @spec dedup_within_clusters([map()]) :: {:ok, %{merged: non_neg_integer(), superseded: non_neg_integer()}}
  def dedup_within_clusters(cluster_maps) do
    config = Application.get_env(:cerno, :dedup, [])
    threshold = Keyword.get(config, :cluster_threshold, 0.88)

    {merged, superseded} =
      Enum.reduce(cluster_maps, {0, 0}, fn cluster_map, {m, s} ->
        # Load insights in this cluster sorted by observation_count desc
        insights =
          from(i in Insight,
            where: i.id in ^cluster_map.insight_ids,
            where: i.status == :active,
            order_by: [desc: i.observation_count]
          )
          |> Repo.all()

        {cluster_merged, cluster_superseded} = dedup_insight_list(insights, threshold)
        {m + cluster_merged, s + cluster_superseded}
      end)

    Logger.info("Intra-cluster dedup: #{merged} merges, #{superseded} superseded")
    {:ok, %{merged: merged, superseded: superseded}}
  end

  defp dedup_insight_list(insights, threshold) do
    # Track which insight IDs have been superseded so we skip them
    superseded_ids = MapSet.new()

    {merged, superseded, _superseded_ids} =
      Enum.reduce(insights, {0, 0, superseded_ids}, fn winner, {m, s, sup} ->
        if MapSet.member?(sup, winner.id) do
          {m, s, sup}
        else
          # Compare winner against all remaining active insights
          losers =
            insights
            |> Enum.filter(fn candidate ->
              candidate.id != winner.id and
                not MapSet.member?(sup, candidate.id) and
                candidate.observation_count <= winner.observation_count
            end)
            |> Enum.filter(fn candidate ->
              winner_emb = to_list(winner.embedding)
              candidate_emb = to_list(candidate.embedding)

              winner_emb != nil and candidate_emb != nil and
                cosine_similarity(winner_emb, candidate_emb) >= threshold
            end)

          if losers == [] do
            {m, s, sup}
          else
            # Absorb all losers into winner
            total_obs =
              Enum.reduce(losers, 0, fn loser, acc -> acc + loser.observation_count end)

            max_seen =
              losers
              |> Enum.map(& &1.last_seen_at)
              |> Enum.reject(&is_nil/1)
              |> case do
                [] -> winner.last_seen_at
                dates -> Enum.max([winner.last_seen_at | dates], DateTime)
              end

            # Update winner
            winner
            |> Insight.changeset(%{
              observation_count: winner.observation_count + total_obs,
              last_seen_at: max_seen
            })
            |> Repo.update()

            # Mark losers as superseded
            loser_ids = Enum.map(losers, & &1.id)

            from(i in Insight, where: i.id in ^loser_ids)
            |> Repo.update_all(set: [status: :superseded])

            new_sup = Enum.reduce(loser_ids, sup, &MapSet.put(&2, &1))
            {m + length(losers), s + length(losers), new_sup}
          end
        end
      end)

    {merged, superseded}
  end

  # --- Cross-cluster contradiction scanning ---

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
  Scan for contradictions between clusters.

  Compares centroids of different clusters. If centroid similarity falls in the
  contradiction range (0.5-0.85), compares member insight pairs across clusters
  using a negation heuristic to determine contradiction type.

  Creates Contradiction records: `:direct` if negation pattern found, `:partial`
  if detected by embedding similarity only. Skips pairs that already have a
  contradiction record.

  Returns `{:ok, count}` of contradictions created.
  """
  @spec scan_cross_cluster_contradictions([map()]) :: {:ok, non_neg_integer()}
  def scan_cross_cluster_contradictions(cluster_maps) do
    config = Application.get_env(:cerno, :dedup, [])
    {low, high} = Keyword.get(config, :contradiction_range, {0.5, 0.85})

    # Build pairs of clusters whose centroids are in the contradiction range
    cluster_pairs =
      for {a, i} <- Enum.with_index(cluster_maps),
          {b, j} <- Enum.with_index(cluster_maps),
          i < j,
          do: {a, b}

    contradiction_count =
      Enum.reduce(cluster_pairs, 0, fn {cluster_a, cluster_b}, total ->
        centroid_sim = cosine_similarity(cluster_a.centroid, cluster_b.centroid)

        if centroid_sim >= low and centroid_sim <= high do
          # Load insights for both clusters
          insights_a =
            from(i in Insight, where: i.id in ^cluster_a.insight_ids, where: i.status == :active)
            |> Repo.all()

          insights_b =
            from(i in Insight, where: i.id in ^cluster_b.insight_ids, where: i.status == :active)
            |> Repo.all()

          # Compare all cross-cluster pairs
          pair_count =
            Enum.reduce(insights_a, 0, fn ia, acc_a ->
              Enum.reduce(insights_b, acc_a, fn ib, acc_b ->
                emb_a = to_list(ia.embedding)
                emb_b = to_list(ib.embedding)

                pair_sim =
                  if emb_a != nil and emb_b != nil do
                    cosine_similarity(emb_a, emb_b)
                  else
                    0.0
                  end

                if pair_sim >= low and pair_sim <= high do
                  case create_cross_contradiction(ia, ib, pair_sim) do
                    :created -> acc_b + 1
                    :exists -> acc_b
                  end
                else
                  acc_b
                end
              end)
            end)

          total + pair_count
        else
          total
        end
      end)

    Logger.info("Cross-cluster contradiction scan: #{contradiction_count} contradictions created")
    {:ok, contradiction_count}
  end

  defp create_cross_contradiction(insight_a, insight_b, similarity) do
    # Normalize order: lower ID first
    {first, second} =
      if insight_a.id < insight_b.id,
        do: {insight_a, insight_b},
        else: {insight_b, insight_a}

    # Check if contradiction already exists
    existing =
      from(c in Contradiction,
        where:
          (c.insight_a_id == ^first.id and c.insight_b_id == ^second.id) or
            (c.insight_a_id == ^second.id and c.insight_b_id == ^first.id)
      )
      |> Repo.one()

    if existing do
      :exists
    else
      contradiction_type = detect_contradiction_type(first.content, second.content)

      description =
        case contradiction_type do
          :direct ->
            "Direct contradiction detected via negation pattern (similarity: #{Float.round(similarity, 3)})"

          :partial ->
            "Partial contradiction detected via cross-cluster embedding similarity (similarity: #{Float.round(similarity, 3)})"
        end

      attrs = %{
        insight_a_id: first.id,
        insight_b_id: second.id,
        contradiction_type: contradiction_type,
        detected_by: "clusterer",
        similarity_score: similarity,
        description: description
      }

      case %Contradiction{} |> Contradiction.changeset(attrs) |> Repo.insert() do
        {:ok, _} -> :created
        {:error, _} -> :exists
      end
    end
  end

  defp detect_contradiction_type(content_a, content_b) do
    a_lower = String.downcase(content_a)
    b_lower = String.downcase(content_b)

    has_negation =
      Enum.any?(@negation_pairs, fn {pos, neg} ->
        (String.contains?(a_lower, pos) and String.contains?(b_lower, neg)) or
          (String.contains?(a_lower, neg) and String.contains?(b_lower, pos))
      end)

    if has_negation, do: :direct, else: :partial
  end

  # --- Helpers ---

  defp to_list(nil), do: nil
  defp to_list(embedding) when is_list(embedding), do: embedding

  defp to_list(%Pgvector{} = vec) do
    Pgvector.to_list(vec)
  end

  defp to_list(embedding) do
    # Fallback: try to convert via Pgvector if it's a struct we don't recognize
    if is_struct(embedding) do
      Pgvector.to_list(embedding)
    else
      embedding
    end
  end
end
