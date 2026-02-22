defmodule Cerno.LongTerm.PromoterTest do
  use ExUnit.Case

  alias Cerno.LongTerm.{Promoter, Principle, Derivation}
  alias Cerno.ShortTerm.Insight
  alias Cerno.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  defp insert_promotable_insight(attrs \\ %{}) do
    now = DateTime.utc_now()
    content = Map.get(attrs, :content, "promotable insight #{System.unique_integer()}")
    emb = Cerno.Embedding.Mock.deterministic_embedding(content)

    defaults = %{
      content: content,
      content_hash: Insight.hash_content(content),
      embedding: emb,
      category: :convention,
      confidence: 0.8,
      observation_count: 5,
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

  describe "promote_insight/1" do
    test "creates a principle and derivation from an insight" do
      insight = insert_promotable_insight(%{content: "Always use pattern matching"})

      assert {:ok, :promoted} = Promoter.promote_insight(insight)

      import Ecto.Query
      principles = Repo.all(from(p in Principle))
      assert length(principles) == 1
      principle = hd(principles)
      assert principle.content == "Always use pattern matching"
      assert principle.category == :heuristic
      assert principle.confidence == insight.confidence
      assert principle.frequency == insight.observation_count

      derivations = Repo.all(from(d in Derivation))
      assert length(derivations) == 1
      assert hd(derivations).principle_id == principle.id
      assert hd(derivations).insight_id == insight.id
    end

    test "skips exact duplicate (same content hash in principles)" do
      content = "Use GenServer for stateful processes"
      insight = insert_promotable_insight(%{content: content})

      # Promote once — creates a principle
      {:ok, :promoted} = Promoter.promote_insight(insight)

      # Trying to promote the same insight again should be skipped
      # (principle with same content_hash already exists)
      assert {:ok, :skipped_exact} = Promoter.promote_insight(insight)

      import Ecto.Query
      assert Repo.aggregate(from(p in Principle), :count) == 1
    end

    test "skips semantic duplicate (high embedding similarity)" do
      # Same embedding = 1.0 similarity, well above 0.92 threshold
      emb = Cerno.Embedding.Mock.deterministic_embedding("shared embedding")

      insight1 = insert_promotable_insight(%{
        content: "Use GenServer for state",
        embedding: emb
      })
      insight2 = insert_promotable_insight(%{
        content: "Use GenServer to manage state",
        embedding: emb
      })

      {:ok, :promoted} = Promoter.promote_insight(insight1)
      assert {:ok, :skipped_semantic} = Promoter.promote_insight(insight2)

      import Ecto.Query
      assert Repo.aggregate(from(p in Principle), :count) == 1
    end

    test "maps insight categories to principle categories" do
      for {insight_cat, expected_principle_cat} <- [
        {:convention, :heuristic},
        {:principle, :principle},
        {:technique, :learning},
        {:warning, :anti_pattern},
        {:pattern, :principle}
      ] do
        content = "category test #{insight_cat} #{System.unique_integer()}"
        insight = insert_promotable_insight(%{content: content, category: insight_cat})
        {:ok, :promoted} = Promoter.promote_insight(insight)

        import Ecto.Query
        principle = Repo.one(from(p in Principle, where: p.content == ^content))
        assert principle.category == expected_principle_cat,
          "Expected #{insight_cat} -> #{expected_principle_cat}, got #{principle.category}"
      end
    end

    test "sets domain from insight" do
      insight = insert_promotable_insight(%{
        content: "Elixir domain test",
        domain: "elixir"
      })

      {:ok, :promoted} = Promoter.promote_insight(insight)

      import Ecto.Query
      principle = Repo.one(from(p in Principle))
      assert principle.domains == ["elixir"]
    end
  end

  describe "promote_eligible/0" do
    test "promotes qualifying insights" do
      # These meet test config criteria (confidence > 0.5, obs >= 1, age >= 0)
      insert_promotable_insight(%{content: "eligible one"})
      insert_promotable_insight(%{content: "eligible two"})

      {:ok, stats} = Promoter.promote_eligible()
      assert stats.promoted == 2
    end

    test "returns zeroes when nothing to promote" do
      {:ok, stats} = Promoter.promote_eligible()
      assert stats.promoted == 0
      assert stats.skipped_exact == 0
      assert stats.skipped_semantic == 0
    end
  end
end
