defmodule Cerno.Tuning.PromoteTest do
  use ExUnit.Case

  alias Cerno.Tuning.Promote
  alias Cerno.ShortTerm.{Insight, Contradiction}
  alias Cerno.LongTerm.{Principle, Derivation}
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

  # --- explain_eligibility/1 ---

  describe "explain_eligibility/1" do
    test "fully eligible insight passes all checks" do
      # Test config: min_confidence 0.5, min_observations 1, min_age_days 0
      insight = insert_insight(%{confidence: 0.8, observation_count: 3})

      result = Promote.explain_eligibility(insight.id)

      assert result.insight_id == insight.id
      assert result.eligible? == true
      assert length(result.checks) == 5
      assert result.nearest_threshold == nil

      assert Enum.all?(result.checks, & &1.pass?)
    end

    test "low confidence fails confidence check" do
      # Test config min_confidence is 0.5, so 0.1 should fail
      insight = insert_insight(%{confidence: 0.1, observation_count: 3})

      result = Promote.explain_eligibility(insight.id)

      assert result.eligible? == false

      confidence_check = Enum.find(result.checks, &(&1.name == :confidence))
      assert confidence_check.pass? == false
      assert confidence_check.actual == 0.1
      assert confidence_check.required == 0.5
      assert_in_delta confidence_check.gap_pct, (0.5 - 0.1) / 0.5, 0.001
    end

    test "low observations fails observations check" do
      # Test config min_observations is 1, so 0 should fail
      insight = insert_insight(%{confidence: 0.8, observation_count: 0})

      result = Promote.explain_eligibility(insight.id)

      assert result.eligible? == false

      obs_check = Enum.find(result.checks, &(&1.name == :observations))
      assert obs_check.pass? == false
      assert obs_check.actual == 0
      assert obs_check.required == 1
      # gap_pct when actual is 0 and required is 1: (1 - 0) / 1 = 1.0
      assert_in_delta obs_check.gap_pct, 1.0, 0.001
    end

    test "unresolved contradiction fails no_contradictions check" do
      insight = insert_insight(%{confidence: 0.8, observation_count: 3})
      other = insert_insight()
      _contradiction = insert_contradiction(insight, other)

      result = Promote.explain_eligibility(insight.id)

      assert result.eligible? == false

      contra_check = Enum.find(result.checks, &(&1.name == :no_contradictions))
      assert contra_check.pass? == false
      assert contra_check.actual == 1
      assert contra_check.required == 0
    end

    test "resolved contradiction does not block promotion" do
      insight = insert_insight(%{confidence: 0.8, observation_count: 3})
      other = insert_insight()
      _contradiction = insert_contradiction(insight, other, %{resolution_status: :resolved})

      result = Promote.explain_eligibility(insight.id)

      contra_check = Enum.find(result.checks, &(&1.name == :no_contradictions))
      assert contra_check.pass? == true
      assert contra_check.actual == 0
    end

    test "already promoted (has Derivation) fails not_already_promoted check" do
      insight = insert_insight(%{confidence: 0.8, observation_count: 3})
      principle = insert_principle()
      _derivation = insert_derivation(principle, insight)

      result = Promote.explain_eligibility(insight.id)

      assert result.eligible? == false

      promoted_check = Enum.find(result.checks, &(&1.name == :not_already_promoted))
      assert promoted_check.pass? == false
      assert promoted_check.actual == true
      assert promoted_check.required == false
    end

    test "nearest_threshold returns the failing check closest to passing" do
      # confidence 0.4 with min 0.5: gap = (0.5 - 0.4) / 0.5 = 0.2
      # observations 0 with min 1: gap = (1 - 0) / 1 = 1.0
      # So confidence (gap 0.2) is nearest threshold
      insight = insert_insight(%{confidence: 0.4, observation_count: 0})

      result = Promote.explain_eligibility(insight.id)

      assert result.eligible? == false
      assert result.nearest_threshold != nil
      assert result.nearest_threshold.name == :confidence
      assert_in_delta result.nearest_threshold.gap_pct, 0.2, 0.001
    end

    test "returns {:error, :not_found} for non-existent ID" do
      assert {:error, :not_found} = Promote.explain_eligibility(-1)
    end
  end

  # --- promotion_summary/0 ---

  describe "promotion_summary/0" do
    test "groups insights by blocking reason" do
      # eligible: meets all criteria (test config: min_confidence 0.5, min_observations 1, min_age_days 0)
      _eligible = insert_insight(%{confidence: 0.8, observation_count: 3})
      # blocked by confidence
      _low_conf = insert_insight(%{confidence: 0.1, observation_count: 3})
      # blocked by contradiction
      contradicted = insert_insight(%{confidence: 0.8, observation_count: 3})
      other = insert_insight(%{confidence: 0.1})
      insert_contradiction(contradicted, other)
      # already promoted
      promoted = insert_insight(%{confidence: 0.8, observation_count: 3})
      principle = insert_principle()
      insert_derivation(principle, promoted)

      summary = Promote.promotion_summary()

      assert length(summary.eligible) >= 1
      assert length(summary.blocked_by_confidence) >= 1
      assert length(summary.blocked_by_contradictions) >= 1
      assert length(summary.already_promoted) >= 1
      assert is_integer(summary.total_active)
    end

    test "returns empty groups on empty DB" do
      summary = Promote.promotion_summary()
      assert summary.eligible == []
      assert summary.blocked_by_confidence == []
      assert summary.blocked_by_observations == []
      assert summary.blocked_by_age == []
      assert summary.blocked_by_contradictions == []
      assert summary.already_promoted == []
      assert summary.total_active == 0
    end

    test "no double-counting — insight in only one group" do
      # This insight fails BOTH confidence and observations
      _both_fail = insert_insight(%{confidence: 0.1, observation_count: 0})

      summary = Promote.promotion_summary()

      all_ids =
        (summary.eligible ++
           summary.blocked_by_confidence ++
           summary.blocked_by_observations ++
           summary.blocked_by_age ++
           summary.blocked_by_contradictions ++
           summary.already_promoted)
        |> Enum.map(& &1.insight.id)

      assert length(all_ids) == length(Enum.uniq(all_ids))
    end

    test "priority: already_promoted takes precedence over contradictions" do
      # Insight that is both contradicted AND already promoted
      insight = insert_insight(%{confidence: 0.8, observation_count: 3})
      other = insert_insight(%{confidence: 0.5})
      insert_contradiction(insight, other)
      principle = insert_principle()
      insert_derivation(principle, insight)

      summary = Promote.promotion_summary()

      promoted_ids = Enum.map(summary.already_promoted, & &1.insight.id)
      contradicted_ids = Enum.map(summary.blocked_by_contradictions, & &1.insight.id)

      assert insight.id in promoted_ids
      refute insight.id in contradicted_ids
    end

    test "priority: contradictions takes precedence over confidence" do
      # Insight that has both low confidence AND a contradiction
      insight = insert_insight(%{confidence: 0.1, observation_count: 3})
      other = insert_insight(%{confidence: 0.5})
      insert_contradiction(insight, other)

      summary = Promote.promotion_summary()

      contradicted_ids = Enum.map(summary.blocked_by_contradictions, & &1.insight.id)
      confidence_ids = Enum.map(summary.blocked_by_confidence, & &1.insight.id)

      assert insight.id in contradicted_ids
      refute insight.id in confidence_ids
    end

    test "total_active matches sum of all groups" do
      insert_insight(%{confidence: 0.8, observation_count: 3})
      insert_insight(%{confidence: 0.1, observation_count: 3})
      insert_insight(%{confidence: 0.8, observation_count: 0})

      summary = Promote.promotion_summary()

      group_total =
        length(summary.eligible) +
          length(summary.blocked_by_confidence) +
          length(summary.blocked_by_observations) +
          length(summary.blocked_by_age) +
          length(summary.blocked_by_contradictions) +
          length(summary.already_promoted)

      assert summary.total_active == group_total
    end

    test "each entry contains insight and eligibility" do
      insert_insight(%{confidence: 0.8, observation_count: 3})

      summary = Promote.promotion_summary()

      [entry] = summary.eligible
      assert %Insight{} = entry.insight
      assert entry.eligibility.eligible? == true
      assert is_list(entry.eligibility.checks)
    end
  end
end
