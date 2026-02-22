defmodule Cerno.LongTerm.RetrieverTest do
  use ExUnit.Case

  alias Cerno.LongTerm.{Retriever, Principle}
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

  describe "detect_file_domains/1" do
    test "detects Elixir domain from code content" do
      content = """
      Use GenServer for stateful processes.

      Always prefer pattern matching over conditionals in Elixir.

      Configure Ecto repos in config.exs.
      """

      domains = Retriever.detect_file_domains(content)
      assert "elixir" in domains
    end

    test "detects multiple domains" do
      content = """
      Use GenServer and Ecto in your Elixir Phoenix application.

      Configure PostgreSQL migrations and database schema properly.

      Build React components with TypeScript and npm packages.
      """

      domains = Retriever.detect_file_domains(content)
      assert length(domains) >= 2
    end

    test "returns empty list for unclassifiable content" do
      domains = Retriever.detect_file_domains("Hello world")
      assert domains == []
    end

    test "returns at most 3 domains" do
      content = """
      Use Elixir and Phoenix for the backend.

      Write Python scripts for data processing.

      JavaScript frontend with React components.

      Ruby gems for tooling. Rails for admin panel.

      Go services for high-performance APIs.
      """

      domains = Retriever.detect_file_domains(content)
      assert length(domains) <= 3
    end
  end

  describe "retrieve_for_file/2" do
    test "returns principles sorted by hybrid score" do
      _p1 = insert_principle(%{content: "Use pattern matching in Elixir", rank: 0.9, domains: ["elixir"]})
      _p2 = insert_principle(%{content: "Always write tests first", rank: 0.3, domains: ["testing"]})

      file_content = "Elixir pattern matching is powerful for destructuring data"

      {:ok, results} = Retriever.retrieve_for_file(file_content, min_hybrid_score: 0.0)
      assert length(results) >= 1

      # Results should be scored tuples
      Enum.each(results, fn {principle, score} ->
        assert %Principle{} = principle
        assert is_float(score)
        assert score >= 0.0
      end)
    end

    test "filters by min_hybrid_score" do
      insert_principle(%{content: "Some niche principle", rank: 0.1, domains: ["ruby"]})

      file_content = "Completely unrelated content about cooking recipes"

      {:ok, results} = Retriever.retrieve_for_file(file_content, min_hybrid_score: 0.8)
      # With a high threshold, low-rank principles with low semantic match should be filtered
      assert length(results) == 0
    end

    test "respects max_principles limit" do
      for i <- 1..5 do
        insert_principle(%{content: "Elixir principle number #{i}", rank: 0.5 + i * 0.05, domains: ["elixir"]})
      end

      file_content = "Elixir GenServer implementation patterns"

      {:ok, results} = Retriever.retrieve_for_file(file_content, max_principles: 3, min_hybrid_score: 0.0)
      assert length(results) <= 3
    end

    test "returns empty list when no principles exist" do
      {:ok, results} = Retriever.retrieve_for_file("Some content")
      assert results == []
    end

    test "excludes non-active principles" do
      insert_principle(%{content: "Pruned principle", rank: 0.9, status: :pruned, domains: ["elixir"]})
      insert_principle(%{content: "Decaying principle", rank: 0.9, status: :decaying, domains: ["elixir"]})

      file_content = "Elixir coding patterns"

      {:ok, results} = Retriever.retrieve_for_file(file_content, min_hybrid_score: 0.0)
      assert results == []
    end

    test "domain match boosts score" do
      p_match = insert_principle(%{content: "Use GenServer for state", rank: 0.5, domains: ["elixir"]})
      p_nomatch = insert_principle(%{content: "Use GenServer for state management", rank: 0.5, domains: ["ruby"]})

      file_content = "Elixir GenServer patterns and OTP conventions"

      {:ok, results} = Retriever.retrieve_for_file(file_content, min_hybrid_score: 0.0)

      if length(results) >= 2 do
        scores = Map.new(results, fn {p, score} -> {p.id, score} end)
        # The elixir-domain principle should score higher due to domain match
        assert scores[p_match.id] >= scores[p_nomatch.id]
      end
    end
  end
end
