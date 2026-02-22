defmodule Cerno.LongTerm.LifecycleTest do
  use ExUnit.Case

  alias Cerno.LongTerm.{Lifecycle, Principle, PrincipleLink}
  alias Cerno.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  defp insert_principle(attrs \\ %{}) do
    content = Map.get(attrs, :content, "principle #{System.unique_integer()}")

    defaults = %{
      content: content,
      content_hash: Cerno.ShortTerm.Insight.hash_content(content),
      embedding: Cerno.Embedding.Mock.deterministic_embedding(content),
      category: :learning,
      tags: [],
      domains: [],
      confidence: 0.7,
      frequency: 3,
      recency_score: 1.0,
      source_quality: 0.5,
      rank: 0.5,
      status: :active
    }

    {:ok, principle} =
      %Principle{}
      |> Principle.changeset(Map.merge(defaults, attrs))
      |> Repo.insert()

    principle
  end

  describe "apply_decay/0" do
    test "returns {:ok, 0} when no principles exist" do
      assert {:ok, 0} = Lifecycle.apply_decay()
    end

    test "does not decay recently updated principles" do
      p = insert_principle(%{recency_score: 1.0})

      {:ok, _} = Lifecycle.apply_decay()

      updated = Repo.get!(Principle, p.id)
      # Should still be close to 1.0 since it was just created
      assert_in_delta updated.recency_score, 1.0, 0.05
    end
  end

  describe "recompute_ranks/0" do
    test "computes rank for principles" do
      p = insert_principle(%{confidence: 0.8, frequency: 5, recency_score: 1.0, rank: 0.0})

      {:ok, count} = Lifecycle.recompute_ranks()
      assert count >= 1

      updated = Repo.get!(Principle, p.id)
      assert updated.rank > 0.0
    end

    test "includes link count in rank" do
      p1 = insert_principle(%{rank: 0.0})
      p2 = insert_principle(%{rank: 0.0})

      # Create a link between them
      %PrincipleLink{}
      |> PrincipleLink.changeset(%{
        source_id: p1.id,
        target_id: p2.id,
        link_type: :reinforces,
        strength: 0.9
      })
      |> Repo.insert!()

      {:ok, _} = Lifecycle.recompute_ranks()

      r1 = Repo.get!(Principle, p1.id)
      assert r1.rank > 0.0
    end
  end

  describe "apply_pruning/0" do
    test "returns zeroes when nothing to prune" do
      insert_principle(%{rank: 0.8})

      {:ok, stats} = Lifecycle.apply_pruning()
      assert stats.decaying == 0
      assert stats.pruned == 0
    end

    test "does not prune recently updated principles even with low rank" do
      insert_principle(%{rank: 0.05})

      {:ok, stats} = Lifecycle.apply_pruning()
      # Just created, so updated_at is recent — should not be pruned
      assert stats.pruned == 0
      assert stats.decaying == 0
    end
  end

  describe "run/0" do
    test "runs full lifecycle without errors" do
      insert_principle()

      assert :ok = Lifecycle.run()
    end
  end
end
