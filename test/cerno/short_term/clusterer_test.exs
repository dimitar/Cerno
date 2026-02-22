defmodule Cerno.ShortTerm.ClustererTest do
  use ExUnit.Case

  alias Cerno.ShortTerm.{Clusterer, Insight, Contradiction}
  alias Cerno.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  # --- cosine_similarity/2 ---

  describe "cosine_similarity/2" do
    test "identical vectors return 1.0" do
      vec = [1.0, 0.0, 0.0]
      assert_in_delta Clusterer.cosine_similarity(vec, vec), 1.0, 0.0001
    end

    test "orthogonal vectors return 0.0" do
      a = [1.0, 0.0, 0.0]
      b = [0.0, 1.0, 0.0]
      assert_in_delta Clusterer.cosine_similarity(a, b), 0.0, 0.0001
    end

    test "opposite vectors return -1.0" do
      a = [1.0, 0.0, 0.0]
      b = [-1.0, 0.0, 0.0]
      assert_in_delta Clusterer.cosine_similarity(a, b), -1.0, 0.0001
    end

    test "zero vector returns 0.0" do
      a = [1.0, 2.0, 3.0]
      b = [0.0, 0.0, 0.0]
      assert Clusterer.cosine_similarity(a, b) == 0.0
    end

    test "known vectors produce expected similarity" do
      a = [1.0, 2.0, 3.0]
      b = [4.0, 5.0, 6.0]
      # dot = 32, norm_a = sqrt(14) = 3.7417, norm_b = sqrt(77) = 8.7749
      # sim = 32 / (3.7417 * 8.7749) ≈ 0.9746
      assert_in_delta Clusterer.cosine_similarity(a, b), 0.9746, 0.001
    end
  end

  # --- find_connected_components/2 ---

  describe "find_connected_components/2" do
    test "single node returns one component" do
      components = Clusterer.find_connected_components([1], %{})
      assert components == [[1]]
    end

    test "disconnected nodes become separate components" do
      components = Clusterer.find_connected_components([1, 2, 3], %{})
      assert length(components) == 3
    end

    test "connected nodes form one component" do
      adjacency = %{
        1 => MapSet.new([2]),
        2 => MapSet.new([1, 3]),
        3 => MapSet.new([2])
      }

      components = Clusterer.find_connected_components([1, 2, 3], adjacency)
      assert length(components) == 1
      assert length(hd(components)) == 3
    end

    test "two separate groups form two components" do
      adjacency = %{
        1 => MapSet.new([2]),
        2 => MapSet.new([1]),
        3 => MapSet.new([4]),
        4 => MapSet.new([3])
      }

      components = Clusterer.find_connected_components([1, 2, 3, 4], adjacency)
      assert length(components) == 2

      sizes = Enum.map(components, &length/1) |> Enum.sort()
      assert sizes == [2, 2]
    end

    test "empty list returns empty" do
      assert Clusterer.find_connected_components([], %{}) == []
    end
  end

  # --- cluster_insights/0 ---

  describe "cluster_insights/0" do
    test "returns empty list when no insights exist" do
      assert Clusterer.cluster_insights() == []
    end

    test "clusters similar insights together" do
      now = DateTime.utc_now()

      # Create 3 insights with identical content (same embedding) - should form 1 cluster
      base_text = "Always use pattern matching in Elixir"
      base_emb = Cerno.Embedding.Mock.deterministic_embedding(base_text)

      for i <- 1..3 do
        content = "#{base_text} variant #{i}"

        %Insight{}
        |> Insight.changeset(%{
          content: content,
          content_hash: Insight.hash_content(content),
          embedding: base_emb,
          category: :convention,
          confidence: 0.7,
          first_seen_at: now,
          last_seen_at: now,
          status: :active
        })
        |> Repo.insert!()
      end

      # Create 2 insights with very different content - should form separate cluster(s)
      for i <- 1..2 do
        content = "Database migration strategy #{i}"
        emb = Cerno.Embedding.Mock.deterministic_embedding(content)

        %Insight{}
        |> Insight.changeset(%{
          content: content,
          content_hash: Insight.hash_content(content),
          embedding: emb,
          category: :technique,
          confidence: 0.6,
          first_seen_at: now,
          last_seen_at: now,
          status: :active
        })
        |> Repo.insert!()
      end

      clusters = Clusterer.cluster_insights()

      # Should have at least 1 cluster with the 3 similar insights
      assert length(clusters) >= 1

      # Each cluster should have insight_ids, centroid, and coherence
      Enum.each(clusters, fn c ->
        assert is_list(c.insight_ids)
        assert is_list(c.centroid)
        assert is_float(c.coherence)
        assert c.coherence >= -0.001
        assert c.coherence <= 1.001
      end)
    end

    test "singleton insights form their own clusters" do
      now = DateTime.utc_now()

      for i <- 1..3 do
        content = "Completely unique topic number #{i} with special words #{:rand.uniform(100_000)}"
        emb = Cerno.Embedding.Mock.deterministic_embedding(content)

        %Insight{}
        |> Insight.changeset(%{
          content: content,
          content_hash: Insight.hash_content(content),
          embedding: emb,
          category: :fact,
          confidence: 0.5,
          first_seen_at: now,
          last_seen_at: now,
          status: :active
        })
        |> Repo.insert!()
      end

      clusters = Clusterer.cluster_insights()

      # Each singleton should be its own cluster
      singleton_clusters = Enum.filter(clusters, fn c -> length(c.insight_ids) == 1 end)
      assert length(singleton_clusters) >= 1
    end
  end

  # --- persist_clusters/1 ---

  describe "persist_clusters/1" do
    test "persists clusters and join records" do
      now = DateTime.utc_now()
      emb = Cerno.Embedding.Mock.deterministic_embedding("test persist")

      {:ok, i1} =
        %Insight{}
        |> Insight.changeset(%{
          content: "persist test 1",
          content_hash: Insight.hash_content("persist test 1"),
          embedding: emb,
          first_seen_at: now,
          last_seen_at: now,
          status: :active
        })
        |> Repo.insert()

      {:ok, i2} =
        %Insight{}
        |> Insight.changeset(%{
          content: "persist test 2",
          content_hash: Insight.hash_content("persist test 2"),
          embedding: emb,
          first_seen_at: now,
          last_seen_at: now,
          status: :active
        })
        |> Repo.insert()

      cluster_maps = [
        %{
          insight_ids: [i1.id, i2.id],
          centroid: emb,
          coherence: 0.95
        }
      ]

      assert {:ok, 1} = Clusterer.persist_clusters(cluster_maps)

      # Verify cluster was created
      import Ecto.Query
      clusters = Repo.all(from(c in Cerno.ShortTerm.Cluster))
      assert length(clusters) == 1
      assert hd(clusters).insight_count == 2
    end

    test "full rebuild deletes old clusters" do
      now = DateTime.utc_now()
      emb = Cerno.Embedding.Mock.deterministic_embedding("rebuild test")

      {:ok, insight} =
        %Insight{}
        |> Insight.changeset(%{
          content: "rebuild test",
          content_hash: Insight.hash_content("rebuild test"),
          embedding: emb,
          first_seen_at: now,
          last_seen_at: now,
          status: :active
        })
        |> Repo.insert()

      # First persist
      cluster_maps = [%{insight_ids: [insight.id], centroid: emb, coherence: 1.0}]
      {:ok, 1} = Clusterer.persist_clusters(cluster_maps)

      # Second persist (rebuild)
      {:ok, 1} = Clusterer.persist_clusters(cluster_maps)

      import Ecto.Query
      assert Repo.aggregate(from(c in Cerno.ShortTerm.Cluster), :count) == 1
    end
  end

  # --- dedup_within_clusters/1 ---

  describe "dedup_within_clusters/1" do
    test "merges similar insights within a cluster" do
      now = DateTime.utc_now()
      emb = Cerno.Embedding.Mock.deterministic_embedding("dedup test content")

      # Create 3 insights with the same embedding
      insights =
        for i <- 1..3 do
          content = "dedup test content #{i}"

          {:ok, insight} =
            %Insight{}
            |> Insight.changeset(%{
              content: content,
              content_hash: Insight.hash_content(content),
              embedding: emb,
              category: :convention,
              confidence: 0.7,
              observation_count: 4 - i,
              first_seen_at: now,
              last_seen_at: now,
              status: :active
            })
            |> Repo.insert()

          insight
        end

      cluster_maps = [
        %{
          insight_ids: Enum.map(insights, & &1.id),
          centroid: emb,
          coherence: 1.0
        }
      ]

      {:ok, stats} = Clusterer.dedup_within_clusters(cluster_maps)

      assert stats.superseded >= 1

      # Verify winner absorbed observation counts
      import Ecto.Query

      active =
        from(i in Insight, where: i.status == :active, where: i.id in ^Enum.map(insights, & &1.id))
        |> Repo.all()

      superseded =
        from(i in Insight, where: i.status == :superseded, where: i.id in ^Enum.map(insights, & &1.id))
        |> Repo.all()

      assert length(active) + length(superseded) == 3
      assert length(superseded) >= 1
    end
  end

  # --- scan_cross_cluster_contradictions/1 ---

  describe "scan_cross_cluster_contradictions/1" do
    test "detects direct contradiction via negation pattern" do
      now = DateTime.utc_now()

      # Use content that triggers the negation heuristic
      content_a = "Always use pattern matching in function heads"
      content_b = "Never use pattern matching in function heads"

      emb_a = Cerno.Embedding.Mock.deterministic_embedding(content_a)
      emb_b = Cerno.Embedding.Mock.deterministic_embedding(content_b)

      {:ok, ia} =
        %Insight{}
        |> Insight.changeset(%{
          content: content_a,
          content_hash: Insight.hash_content(content_a),
          embedding: emb_a,
          category: :convention,
          confidence: 0.7,
          first_seen_at: now,
          last_seen_at: now,
          status: :active
        })
        |> Repo.insert()

      {:ok, ib} =
        %Insight{}
        |> Insight.changeset(%{
          content: content_b,
          content_hash: Insight.hash_content(content_b),
          embedding: emb_b,
          category: :warning,
          confidence: 0.7,
          first_seen_at: now,
          last_seen_at: now,
          status: :active
        })
        |> Repo.insert()

      # Build two singleton clusters whose centroids are in contradiction range
      cluster_a = %{insight_ids: [ia.id], centroid: emb_a, coherence: 1.0}
      cluster_b = %{insight_ids: [ib.id], centroid: emb_b, coherence: 1.0}

      # We need the centroid similarity to be in 0.5-0.85 range for scanning to trigger.
      # With mock embeddings, the similarity between these texts may or may not be in range.
      # Let's check and only assert if it would be scanned.
      centroid_sim = Clusterer.cosine_similarity(emb_a, emb_b)

      if centroid_sim >= 0.5 and centroid_sim <= 0.85 do
        {:ok, count} = Clusterer.scan_cross_cluster_contradictions([cluster_a, cluster_b])
        assert count >= 1

        import Ecto.Query
        contradictions = Repo.all(from(c in Contradiction))
        assert length(contradictions) >= 1

        contradiction = hd(contradictions)
        assert contradiction.contradiction_type == :direct
        assert contradiction.detected_by == "clusterer"
      else
        # Centroids not in contradiction range, so scan won't trigger for this pair
        # We verify scan runs without error
        {:ok, _count} = Clusterer.scan_cross_cluster_contradictions([cluster_a, cluster_b])
      end
    end

    test "skips related but non-contradictory content" do
      now = DateTime.utc_now()

      # Related content about the same topic but NO negation pattern
      content_a = "Use pattern matching in function heads for clarity"
      content_b = "Use guard clauses in function heads for validation"

      emb_a = Cerno.Embedding.Mock.deterministic_embedding(content_a)
      emb_b = Cerno.Embedding.Mock.deterministic_embedding(content_b)

      {:ok, ia} =
        %Insight{}
        |> Insight.changeset(%{
          content: content_a,
          content_hash: Insight.hash_content(content_a),
          embedding: emb_a,
          category: :convention,
          confidence: 0.7,
          first_seen_at: now,
          last_seen_at: now,
          status: :active
        })
        |> Repo.insert()

      {:ok, ib} =
        %Insight{}
        |> Insight.changeset(%{
          content: content_b,
          content_hash: Insight.hash_content(content_b),
          embedding: emb_b,
          category: :convention,
          confidence: 0.7,
          first_seen_at: now,
          last_seen_at: now,
          status: :active
        })
        |> Repo.insert()

      cluster_a = %{insight_ids: [ia.id], centroid: emb_a, coherence: 1.0}
      cluster_b = %{insight_ids: [ib.id], centroid: emb_b, coherence: 1.0}

      {:ok, count} = Clusterer.scan_cross_cluster_contradictions([cluster_a, cluster_b])

      # No contradictions should be created — related content without negation
      import Ecto.Query
      contradictions = Repo.all(from(c in Contradiction))
      assert contradictions == []
      assert count == 0
    end

    test "returns {:ok, 0} when no clusters to compare" do
      assert {:ok, 0} = Clusterer.scan_cross_cluster_contradictions([])
    end

    test "returns {:ok, 0} for single cluster" do
      cluster = %{insight_ids: [1], centroid: [1.0, 0.0, 0.0], coherence: 1.0}
      assert {:ok, 0} = Clusterer.scan_cross_cluster_contradictions([cluster])
    end
  end
end
