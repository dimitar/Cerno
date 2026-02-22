defmodule Cerno.ShortTerm.InsightTest do
  use ExUnit.Case

  alias Cerno.ShortTerm.Insight
  alias Cerno.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  describe "changeset/2" do
    test "valid with required fields" do
      changeset = Insight.changeset(%Insight{}, %{
        content: "Use pattern matching",
        content_hash: Insight.hash_content("Use pattern matching")
      })

      assert changeset.valid?
    end

    test "requires content" do
      changeset = Insight.changeset(%Insight{}, %{content_hash: "abc"})
      refute changeset.valid?
      assert {:content, _} = hd(changeset.errors)
    end

    test "requires content_hash" do
      changeset = Insight.changeset(%Insight{}, %{content: "test"})
      refute changeset.valid?
    end

    test "validates confidence range" do
      changeset = Insight.changeset(%Insight{}, %{
        content: "test",
        content_hash: "abc",
        confidence: 1.5
      })

      refute changeset.valid?
    end

    test "accepts valid category" do
      changeset = Insight.changeset(%Insight{}, %{
        content: "test",
        content_hash: "abc",
        category: :convention
      })

      assert changeset.valid?
    end
  end

  describe "hash_content/1" do
    test "produces consistent SHA-256 hash" do
      hash1 = Insight.hash_content("hello world")
      hash2 = Insight.hash_content("hello world")
      assert hash1 == hash2
    end

    test "different content produces different hash" do
      refute Insight.hash_content("foo") == Insight.hash_content("bar")
    end

    test "returns lowercase hex string" do
      hash = Insight.hash_content("test")
      assert hash =~ ~r/^[0-9a-f]{64}$/
    end
  end

  describe "CRUD operations" do
    test "inserts and retrieves an insight" do
      now = DateTime.utc_now()

      {:ok, insight} =
        %Insight{}
        |> Insight.changeset(%{
          content: "Always use pattern matching in Elixir.",
          content_hash: Insight.hash_content("Always use pattern matching in Elixir."),
          category: :convention,
          tags: ["elixir", "style"],
          domain: "elixir",
          confidence: 0.7,
          observation_count: 1,
          first_seen_at: now,
          last_seen_at: now,
          status: :active
        })
        |> Repo.insert()

      retrieved = Repo.get!(Insight, insight.id)
      assert retrieved.content == "Always use pattern matching in Elixir."
      assert retrieved.category == :convention
      assert retrieved.tags == ["elixir", "style"]
    end

    test "enforces unique content_hash" do
      hash = Insight.hash_content("duplicate content")

      {:ok, _} =
        %Insight{}
        |> Insight.changeset(%{content: "duplicate content", content_hash: hash})
        |> Repo.insert()

      {:error, changeset} =
        %Insight{}
        |> Insight.changeset(%{content: "duplicate content", content_hash: hash})
        |> Repo.insert()

      assert {:content_hash, _} = hd(changeset.errors)
    end
  end

  describe "find_similar/2" do
    test "returns empty list when no insights exist" do
      embedding = Cerno.Embedding.Mock.deterministic_embedding("test")
      assert Insight.find_similar(embedding) == []
    end

    test "finds similar insights by embedding" do
      now = DateTime.utc_now()
      embedding = Cerno.Embedding.Mock.deterministic_embedding("Use pattern matching")

      {:ok, _insight} =
        %Insight{}
        |> Insight.changeset(%{
          content: "Use pattern matching",
          content_hash: Insight.hash_content("Use pattern matching"),
          embedding: embedding,
          category: :convention,
          confidence: 0.7,
          first_seen_at: now,
          last_seen_at: now,
          status: :active
        })
        |> Repo.insert()

      # Searching with the same embedding should find it
      results = Insight.find_similar(embedding, threshold: 0.9)
      assert length(results) == 1
      assert [{%Insight{}, similarity}] = results
      assert similarity >= 0.9
    end

    test "excludes insight by exclude_id" do
      now = DateTime.utc_now()
      embedding = Cerno.Embedding.Mock.deterministic_embedding("test content")

      {:ok, insight} =
        %Insight{}
        |> Insight.changeset(%{
          content: "test content",
          content_hash: Insight.hash_content("test content"),
          embedding: embedding,
          first_seen_at: now,
          last_seen_at: now,
          status: :active
        })
        |> Repo.insert()

      results = Insight.find_similar(embedding, exclude_id: insight.id)
      assert results == []
    end
  end
end
