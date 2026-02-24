defmodule Cerno.Tuning.InspectTest do
  use ExUnit.Case

  alias Cerno.Tuning.Inspect
  alias Cerno.ShortTerm.{Insight, InsightSource, Contradiction, Cluster}
  alias Cerno.LongTerm.{Principle, Derivation, PrincipleLink}
  alias Cerno.Embedding.Mock, as: EmbeddingMock
  alias Cerno.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  # --- Helpers ---

  defp insert_insight(attrs \\ %{}) do
    now = DateTime.utc_now()
    content = Map.get(attrs, :content, "test insight #{System.unique_integer()}")

    defaults = %{
      content: content,
      content_hash: Insight.hash_content(content),
      category: :convention,
      confidence: 0.5,
      observation_count: 1,
      first_seen_at: now,
      last_seen_at: now,
      status: :active
    }

    {:ok, insight} =
      %Insight{}
      |> Insight.changeset(Map.merge(defaults, attrs))
      |> Repo.insert()

    insight
  end

  defp insert_principle(attrs \\ %{}) do
    content = Map.get(attrs, :content, "test principle #{System.unique_integer()}")
    embedding = EmbeddingMock.deterministic_embedding(content)

    defaults = %{
      content: content,
      content_hash: Insight.hash_content(content),
      embedding: embedding,
      category: :heuristic,
      confidence: 0.6,
      frequency: 3,
      recency_score: 0.8,
      source_quality: 0.5,
      rank: 0.5,
      domains: ["elixir"],
      status: :active
    }

    {:ok, principle} =
      %Principle{}
      |> Principle.changeset(Map.merge(defaults, attrs))
      |> Repo.insert()

    principle
  end

  defp insert_contradiction(insight_a, insight_b, attrs \\ %{}) do
    defaults = %{
      insight_a_id: insight_a.id,
      insight_b_id: insight_b.id,
      contradiction_type: :direct,
      detected_by: "test",
      similarity_score: 0.7
    }

    {:ok, c} =
      %Contradiction{}
      |> Contradiction.changeset(Map.merge(defaults, attrs))
      |> Repo.insert()

    c
  end

  defp insert_cluster(attrs \\ %{}) do
    defaults = %{
      name: "test cluster #{System.unique_integer()}",
      coherence_score: 0.8,
      insight_count: 0
    }

    {:ok, cluster} =
      %Cluster{}
      |> Cluster.changeset(Map.merge(defaults, attrs))
      |> Repo.insert()

    cluster
  end

  defp add_insight_to_cluster(insight, cluster) do
    Repo.insert_all("cluster_insights", [
      %{cluster_id: cluster.id, insight_id: insight.id}
    ])
  end

  defp insert_source(insight, attrs \\ %{}) do
    defaults = %{
      insight_id: insight.id,
      fragment_id: "frag-#{System.unique_integer([:positive])}",
      source_path: "/tmp/project/CLAUDE.md",
      source_project: "project"
    }

    {:ok, source} =
      %InsightSource{}
      |> InsightSource.changeset(Map.merge(defaults, attrs))
      |> Repo.insert()

    source
  end

  defp insert_derivation(principle, insight, attrs \\ %{}) do
    defaults = %{
      principle_id: principle.id,
      insight_id: insight.id,
      contribution_weight: 1.0
    }

    {:ok, d} =
      %Derivation{}
      |> Derivation.changeset(Map.merge(defaults, attrs))
      |> Repo.insert()

    d
  end

  defp insert_link(source_principle, target_principle, attrs \\ %{}) do
    defaults = %{
      source_id: source_principle.id,
      target_id: target_principle.id,
      link_type: :reinforces,
      strength: 0.7
    }

    {:ok, link} =
      %PrincipleLink{}
      |> PrincipleLink.changeset(Map.merge(defaults, attrs))
      |> Repo.insert()

    link
  end

  # --- stats/0 ---

  describe "stats/0" do
    test "returns counts for empty database" do
      stats = Inspect.stats()

      assert stats.insights.total == 0
      assert stats.principles.total == 0
      assert stats.contradictions.total == 0
      assert stats.clusters.total == 0
    end

    test "returns correct counts and breakdowns" do
      _i1 = insert_insight(%{status: :active, category: :convention, domain: "elixir"})
      i2 = insert_insight(%{status: :active, category: :principle, domain: "elixir"})
      i3 = insert_insight(%{status: :contradicted, category: :convention, domain: "otp"})
      _p1 = insert_principle()
      _c1 = insert_contradiction(i2, i3)
      cluster = insert_cluster()
      add_insight_to_cluster(i2, cluster)

      stats = Inspect.stats()

      assert stats.insights.total == 3
      assert stats.insights.by_status[:active] == 2
      assert stats.insights.by_status[:contradicted] == 1
      assert stats.insights.by_category[:convention] == 2
      assert stats.insights.by_category[:principle] == 1
      assert stats.principles.total == 1
      assert stats.contradictions.total == 1
      assert stats.clusters.total == 1
    end
  end

  # --- list_insights/1 ---

  describe "list_insights/1" do
    test "returns all insights with default options" do
      insert_insight(%{content: "first"})
      insert_insight(%{content: "second"})

      results = Inspect.list_insights()
      assert length(results) == 2
    end

    test "filters by status" do
      insert_insight(%{status: :active})
      insert_insight(%{status: :contradicted})

      results = Inspect.list_insights(status: :active)
      assert length(results) == 1
      assert hd(results).status == :active
    end

    test "filters by category" do
      insert_insight(%{category: :convention})
      insert_insight(%{category: :warning})

      results = Inspect.list_insights(category: :convention)
      assert length(results) == 1
      assert hd(results).category == :convention
    end

    test "filters by domain" do
      insert_insight(%{domain: "elixir"})
      insert_insight(%{domain: "python"})

      results = Inspect.list_insights(domain: "elixir")
      assert length(results) == 1
      assert hd(results).domain == "elixir"
    end

    test "filters by min_confidence" do
      insert_insight(%{confidence: 0.9})
      insert_insight(%{confidence: 0.3})

      results = Inspect.list_insights(min_confidence: 0.5)
      assert length(results) == 1
      assert hd(results).confidence == 0.9
    end

    test "filters by search (ilike)" do
      insert_insight(%{content: "Use pattern matching always"})
      insert_insight(%{content: "Avoid global state"})

      results = Inspect.list_insights(search: "pattern")
      assert length(results) == 1
      assert hd(results).content =~ "pattern"
    end

    test "sorts by confidence" do
      insert_insight(%{confidence: 0.3})
      insert_insight(%{confidence: 0.9})

      results = Inspect.list_insights(sort_by: :confidence)
      assert hd(results).confidence == 0.9
    end

    test "sorts by observation_count" do
      insert_insight(%{observation_count: 1})
      insert_insight(%{observation_count: 10})

      results = Inspect.list_insights(sort_by: :observation_count)
      assert hd(results).observation_count == 10
    end

    test "respects limit" do
      for _ <- 1..5, do: insert_insight()

      results = Inspect.list_insights(limit: 2)
      assert length(results) == 2
    end
  end

  # --- list_principles/1 ---

  describe "list_principles/1" do
    test "returns all principles with default options" do
      insert_principle(%{content: "first"})
      insert_principle(%{content: "second"})

      results = Inspect.list_principles()
      assert length(results) == 2
    end

    test "filters by status" do
      insert_principle(%{status: :active})
      insert_principle(%{status: :decaying})

      results = Inspect.list_principles(status: :active)
      assert length(results) == 1
      assert hd(results).status == :active
    end

    test "filters by category" do
      insert_principle(%{category: :heuristic})
      insert_principle(%{category: :anti_pattern})

      results = Inspect.list_principles(category: :heuristic)
      assert length(results) == 1
      assert hd(results).category == :heuristic
    end

    test "filters by domain using array contains" do
      insert_principle(%{domains: ["elixir", "otp"]})
      insert_principle(%{domains: ["python"]})

      results = Inspect.list_principles(domain: "elixir")
      assert length(results) == 1
      assert "elixir" in hd(results).domains
    end

    test "filters by min_confidence" do
      insert_principle(%{confidence: 0.9})
      insert_principle(%{confidence: 0.3})

      results = Inspect.list_principles(min_confidence: 0.5)
      assert length(results) == 1
      assert hd(results).confidence == 0.9
    end

    test "filters by search" do
      insert_principle(%{content: "Always use pattern matching"})
      insert_principle(%{content: "Avoid mutable state"})

      results = Inspect.list_principles(search: "pattern")
      assert length(results) == 1
      assert hd(results).content =~ "pattern"
    end

    test "sorts by rank" do
      insert_principle(%{rank: 0.3})
      insert_principle(%{rank: 0.9})

      results = Inspect.list_principles(sort_by: :rank)
      assert hd(results).rank == 0.9
    end

    test "sorts by frequency" do
      insert_principle(%{frequency: 1})
      insert_principle(%{frequency: 20})

      results = Inspect.list_principles(sort_by: :frequency)
      assert hd(results).frequency == 20
    end

    test "respects limit" do
      for _ <- 1..5, do: insert_principle()

      results = Inspect.list_principles(limit: 2)
      assert length(results) == 2
    end
  end

  # --- get_insight/1 ---

  describe "get_insight/1" do
    test "returns insight with preloaded associations" do
      insight = insert_insight()
      _source = insert_source(insight)
      other = insert_insight()
      _contradiction = insert_contradiction(insight, other)

      cluster = insert_cluster()
      add_insight_to_cluster(insight, cluster)

      principle = insert_principle()
      _derivation = insert_derivation(principle, insight)

      assert {:ok, result} = Inspect.get_insight(insight.id)
      assert result.id == insight.id
      assert length(result.sources) == 1
      assert length(result.contradictions_as_first) == 1
      assert length(result.clusters) >= 1
      assert length(result.derived_principles) == 1
      assert hd(result.derived_principles).id == principle.id
    end

    test "returns error for non-existent ID" do
      assert {:error, :not_found} = Inspect.get_insight(-1)
    end
  end

  # --- get_principle/1 ---

  describe "get_principle/1" do
    test "returns principle with preloaded associations and rank breakdown" do
      principle = insert_principle()
      insight = insert_insight()
      _derivation = insert_derivation(principle, insight)

      other_principle = insert_principle()
      _link = insert_link(principle, other_principle)

      assert {:ok, result} = Inspect.get_principle(principle.id)
      assert result.id == principle.id
      assert length(result.derivations) == 1
      assert hd(result.derivations).insight.id == insight.id
      assert length(result.links_as_source) == 1
      assert Map.has_key?(result, :rank_breakdown)
      assert is_float(result.rank_breakdown.confidence)
    end

    test "returns error for non-existent ID" do
      assert {:error, :not_found} = Inspect.get_principle(-1)
    end
  end

  # --- list_fragments/1 ---

  describe "list_fragments/1" do
    test "parses fragments from a CLAUDE.md file" do
      dir = System.tmp_dir!()
      path = Path.join(dir, "CLAUDE.md")

      content = """
      # Project

      ## Overview

      This is the overview section.

      ## Rules

      Always use pattern matching.
      """

      File.write!(path, content)

      assert {:ok, fragments} = Inspect.list_fragments(path)
      assert length(fragments) >= 2

      headings = Enum.map(fragments, & &1.section_heading)
      assert "Overview" in headings
      assert "Rules" in headings
    after
      dir = System.tmp_dir!()
      File.rm(Path.join(dir, "CLAUDE.md"))
    end

    test "returns error for non-existent file" do
      result = Inspect.list_fragments("/nonexistent/CLAUDE.md")
      assert {:error, _} = result
    end
  end
end
