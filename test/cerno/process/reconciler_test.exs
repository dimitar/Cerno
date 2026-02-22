defmodule Cerno.Process.ReconcilerTest do
  use ExUnit.Case

  alias Cerno.Process.Reconciler
  alias Cerno.ShortTerm.{Insight, Contradiction}
  alias Cerno.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    # Allow the task supervisor process to use our sandbox connection
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp insert_insight(attrs \\ %{}) do
    now = DateTime.utc_now()
    content = Map.get(attrs, :content, "test insight #{System.unique_integer()}")
    emb = Cerno.Embedding.Mock.deterministic_embedding(content)

    defaults = %{
      content: content,
      content_hash: Insight.hash_content(content),
      embedding: emb,
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

  describe "promotion_candidates/0" do
    test "returns insights meeting promotion criteria" do
      # Test config has: min_confidence: 0.5, min_observations: 1, min_age_days: 0
      insert_insight(%{confidence: 0.8, observation_count: 5})

      candidates = Reconciler.promotion_candidates()
      assert length(candidates) >= 1
    end

    test "excludes low confidence insights" do
      insert_insight(%{confidence: 0.1, observation_count: 5})

      candidates = Reconciler.promotion_candidates()
      assert Enum.empty?(candidates)
    end

    test "excludes insights with unresolved contradictions" do
      insight_a = insert_insight(%{confidence: 0.8, observation_count: 5})
      insight_b = insert_insight(%{confidence: 0.8, observation_count: 5})

      %Contradiction{}
      |> Contradiction.changeset(%{
        insight_a_id: insight_a.id,
        insight_b_id: insight_b.id,
        contradiction_type: :direct,
        detected_by: "test",
        similarity_score: 0.7
      })
      |> Repo.insert!()

      candidates = Reconciler.promotion_candidates()
      candidate_ids = Enum.map(candidates, & &1.id)
      refute insight_a.id in candidate_ids
      refute insight_b.id in candidate_ids
    end

    test "excludes superseded insights" do
      insert_insight(%{confidence: 0.8, observation_count: 5, status: :superseded})

      candidates = Reconciler.promotion_candidates()
      assert Enum.empty?(candidates)
    end
  end

  describe "reconcile/0 integration" do
    test "runs full pipeline without errors" do
      # Insert some test insights
      insert_insight(%{confidence: 0.6, observation_count: 3})
      insert_insight(%{confidence: 0.7, observation_count: 2})

      # Subscribe to completion broadcast
      Phoenix.PubSub.subscribe(Cerno.PubSub, "reconciliation:complete")

      # Trigger reconciliation
      Reconciler.reconcile()

      # Wait for completion
      assert_receive :reconciliation_complete, 5_000
    end

    test "creates clusters from similar insights" do
      emb = Cerno.Embedding.Mock.deterministic_embedding("clustering test base")

      for i <- 1..3 do
        content = "clustering test variant #{i}"

        %Insight{}
        |> Insight.changeset(%{
          content: content,
          content_hash: Insight.hash_content(content),
          embedding: emb,
          category: :convention,
          confidence: 0.7,
          observation_count: 1,
          first_seen_at: DateTime.utc_now(),
          last_seen_at: DateTime.utc_now(),
          status: :active
        })
        |> Repo.insert!()
      end

      Phoenix.PubSub.subscribe(Cerno.PubSub, "reconciliation:complete")
      Reconciler.reconcile()
      assert_receive :reconciliation_complete, 5_000

      # Verify clusters were created
      import Ecto.Query
      cluster_count = Repo.aggregate(from(c in Cerno.ShortTerm.Cluster), :count)
      assert cluster_count >= 1
    end
  end
end
