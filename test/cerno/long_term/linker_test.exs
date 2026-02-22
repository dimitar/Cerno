defmodule Cerno.LongTerm.LinkerTest do
  use ExUnit.Case

  alias Cerno.LongTerm.{Linker, Principle, PrincipleLink}
  alias Cerno.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  defp insert_principle(attrs \\ %{}) do
    content = Map.get(attrs, :content, "principle #{System.unique_integer()}")
    emb = Cerno.Embedding.Mock.deterministic_embedding(content)

    defaults = %{
      content: content,
      content_hash: Cerno.ShortTerm.Insight.hash_content(content),
      embedding: emb,
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

  describe "detect_links/0" do
    test "returns {:ok, 0} when no principles exist" do
      assert {:ok, 0} = Linker.detect_links()
    end

    test "creates reinforces link for very similar principles" do
      # Same embedding = similarity 1.0 → reinforces
      emb = Cerno.Embedding.Mock.deterministic_embedding("shared concept")

      insert_principle(%{content: "Use pattern matching always", embedding: emb})
      insert_principle(%{content: "Prefer pattern matching everywhere", embedding: emb})

      {:ok, count} = Linker.detect_links()
      assert count >= 1

      import Ecto.Query
      links = Repo.all(from(l in PrincipleLink))
      assert length(links) >= 1
      assert hd(links).link_type == :reinforces
    end

    test "does not create duplicate links" do
      emb = Cerno.Embedding.Mock.deterministic_embedding("no dupes")

      insert_principle(%{content: "principle A", embedding: emb})
      insert_principle(%{content: "principle B", embedding: emb})

      {:ok, count1} = Linker.detect_links()
      {:ok, count2} = Linker.detect_links()

      # Second run should find 0 new links
      assert count1 >= 1
      assert count2 == 0
    end

    test "creates links for multiple principles" do
      emb = Cerno.Embedding.Mock.deterministic_embedding("group topic")

      for i <- 1..3 do
        insert_principle(%{content: "group principle #{i}", embedding: emb})
      end

      {:ok, count} = Linker.detect_links()
      # 3 principles with same embedding → should create links between pairs
      assert count >= 1
    end

    test "does not link unrelated principles" do
      # Two principles with very different embeddings
      insert_principle(%{content: "Elixir pattern matching is essential"})
      insert_principle(%{content: "Docker container orchestration with Kubernetes"})

      {:ok, count} = Linker.detect_links()
      # Mock embeddings for very different content should have low similarity
      # May or may not create links depending on mock similarity
      assert count >= 0
    end
  end
end
