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
end
