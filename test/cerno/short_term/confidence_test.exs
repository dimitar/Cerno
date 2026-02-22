defmodule Cerno.ShortTerm.ConfidenceTest do
  use ExUnit.Case

  alias Cerno.ShortTerm.{Confidence, Insight, InsightSource, Contradiction}
  alias Cerno.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

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

  defp add_source(insight, project) do
    %InsightSource{}
    |> InsightSource.changeset(%{
      insight_id: insight.id,
      fragment_id: "frag-#{System.unique_integer([:positive])}",
      source_path: "/tmp/#{project}/CLAUDE.md",
      source_project: project
    })
    |> Repo.insert!()
  end

  defp add_contradiction(insight_a, insight_b) do
    %Contradiction{}
    |> Contradiction.changeset(%{
      insight_a_id: insight_a.id,
      insight_b_id: insight_b.id,
      contradiction_type: :direct,
      detected_by: "test",
      similarity_score: 0.7
    })
    |> Repo.insert!()
  end

  # --- distinct_project_count/1 ---

  describe "distinct_project_count/1" do
    test "returns 1 when no sources exist" do
      insight = insert_insight()
      assert Confidence.distinct_project_count(insight) == 1
    end

    test "counts distinct projects" do
      insight = insert_insight()
      add_source(insight, "project-a")
      add_source(insight, "project-b")
      add_source(insight, "project-c")

      assert Confidence.distinct_project_count(insight) == 3
    end

    test "deduplicates same project" do
      insight = insert_insight()
      add_source(insight, "project-a")
      add_source(insight, "project-a")

      assert Confidence.distinct_project_count(insight) == 1
    end
  end

  # --- has_unresolved_contradictions?/1 ---

  describe "has_unresolved_contradictions?/1" do
    test "returns false when no contradictions" do
      insight = insert_insight()
      refute Confidence.has_unresolved_contradictions?(insight)
    end

    test "returns true when unresolved contradiction exists" do
      insight_a = insert_insight()
      insight_b = insert_insight()
      add_contradiction(insight_a, insight_b)

      assert Confidence.has_unresolved_contradictions?(insight_a)
      assert Confidence.has_unresolved_contradictions?(insight_b)
    end

    test "returns false when contradiction is resolved" do
      insight_a = insert_insight()
      insight_b = insert_insight()
      contradiction = add_contradiction(insight_a, insight_b)

      contradiction
      |> Contradiction.changeset(%{resolution_status: :resolved})
      |> Repo.update!()

      refute Confidence.has_unresolved_contradictions?(insight_a)
    end
  end

  # --- compute_adjusted_confidence/1 ---

  describe "compute_adjusted_confidence/1" do
    test "multi-project boost increases confidence" do
      insight = insert_insight(%{confidence: 0.5})
      add_source(insight, "project-a")
      add_source(insight, "project-b")
      add_source(insight, "project-c")

      adjusted = Confidence.compute_adjusted_confidence(insight)
      # Boost: 0.05 * (3 - 1) = 0.10
      assert adjusted > 0.5
    end

    test "stale insight gets decay" do
      stale_date = DateTime.add(DateTime.utc_now(), -100, :day)
      insight = insert_insight(%{confidence: 0.8, last_seen_at: stale_date})

      adjusted = Confidence.compute_adjusted_confidence(insight)
      # Decay: 0.8 * 0.9 = 0.72
      assert adjusted < 0.8
    end

    test "recent insight does not get stale decay" do
      recent_date = DateTime.add(DateTime.utc_now(), -10, :day)
      insight = insert_insight(%{confidence: 0.8, last_seen_at: recent_date})

      adjusted = Confidence.compute_adjusted_confidence(insight)
      # No decay, no boost (1 project), observation floor may apply
      assert adjusted >= 0.5
    end

    test "contradiction penalty reduces confidence" do
      insight_a = insert_insight(%{confidence: 0.8, observation_count: 1})
      insight_b = insert_insight()
      add_contradiction(insight_a, insight_b)

      adjusted = Confidence.compute_adjusted_confidence(insight_a)
      # Penalty: 0.8 * 0.8 = 0.64
      assert adjusted < 0.8
    end

    test "observation floor prevents dropping too low" do
      insight = insert_insight(%{confidence: 0.1, observation_count: 20})

      adjusted = Confidence.compute_adjusted_confidence(insight)
      # Floor: min(log(21)/log(50), 0.6) ≈ 0.779 → capped at 0.6
      # But observation floor = max(adjusted, floor) so it should be at least the floor
      floor = min(:math.log(21) / :math.log(50), 0.6)
      assert adjusted >= floor - 0.001
    end

    test "confidence is clamped to 1.0" do
      insight = insert_insight(%{confidence: 0.95, observation_count: 50})
      add_source(insight, "project-a")
      add_source(insight, "project-b")
      add_source(insight, "project-c")
      add_source(insight, "project-d")
      add_source(insight, "project-e")

      adjusted = Confidence.compute_adjusted_confidence(insight)
      assert adjusted <= 1.0
    end

    test "confidence is clamped to 0.0 minimum" do
      # Low confidence, stale, contradicted, low observation count
      stale_date = DateTime.add(DateTime.utc_now(), -100, :day)
      insight = insert_insight(%{confidence: 0.01, observation_count: 1, last_seen_at: stale_date})

      adjusted = Confidence.compute_adjusted_confidence(insight)
      assert adjusted >= 0.0
    end
  end

  # --- adjust_all/0 ---

  describe "adjust_all/0" do
    test "adjusts all active insights" do
      insert_insight(%{confidence: 0.5})
      insert_insight(%{confidence: 0.7})
      insert_insight(%{confidence: 0.3, status: :superseded})

      {:ok, count} = Confidence.adjust_all()
      # Only active insights should be adjusted
      assert count == 2
    end

    test "returns {:ok, 0} when no active insights" do
      assert {:ok, 0} = Confidence.adjust_all()
    end
  end
end
