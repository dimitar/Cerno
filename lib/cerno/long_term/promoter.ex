defmodule Cerno.LongTerm.Promoter do
  @moduledoc """
  Promotes eligible Insights into Principles.

  An Insight is promoted when it meets the criteria defined in
  `:cerno, :promotion` config (confidence, observation count, age,
  no unresolved contradictions, not already promoted).

  Promotion includes exact and semantic deduplication against existing
  Principles to avoid creating duplicates.
  """

  import Ecto.Query
  require Logger

  alias Cerno.Repo
  alias Cerno.ShortTerm.Insight
  alias Cerno.LongTerm.{Principle, Derivation}

  @category_map %{
    convention: :heuristic,
    principle: :principle,
    technique: :learning,
    warning: :anti_pattern,
    preference: :heuristic,
    fact: :learning,
    pattern: :principle
  }

  @doc """
  Promote all eligible insights to principles.

  Returns `{:ok, %{promoted: count, skipped_exact: count, skipped_semantic: count}}`.
  """
  @spec promote_eligible() :: {:ok, map()}
  def promote_eligible do
    candidates = Cerno.Process.Reconciler.promotion_candidates()
    Logger.info("Promoting: #{length(candidates)} candidates")

    stats =
      Enum.reduce(candidates, %{promoted: 0, skipped_exact: 0, skipped_semantic: 0}, fn insight, acc ->
        case promote_insight(insight) do
          {:ok, :promoted} -> %{acc | promoted: acc.promoted + 1}
          {:ok, :skipped_exact} -> %{acc | skipped_exact: acc.skipped_exact + 1}
          {:ok, :skipped_semantic} -> %{acc | skipped_semantic: acc.skipped_semantic + 1}
          {:error, reason} ->
            Logger.warning("Failed to promote insight #{insight.id}: #{inspect(reason)}")
            acc
        end
      end)

    Logger.info("Promotion complete: #{stats.promoted} promoted, #{stats.skipped_exact} exact dupes, #{stats.skipped_semantic} semantic dupes")
    {:ok, stats}
  end

  @doc """
  Promote a single insight to a principle.

  Returns `{:ok, :promoted}`, `{:ok, :skipped_exact}`, `{:ok, :skipped_semantic}`,
  or `{:error, reason}`.
  """
  @spec promote_insight(%Insight{}) :: {:ok, atom()} | {:error, term()}
  def promote_insight(%Insight{} = insight) do
    content_hash = Insight.hash_content(insight.content)

    # Step 1: Exact dedup — check if a principle with the same content hash exists
    case Repo.get_by(Principle, content_hash: content_hash) do
      %Principle{} = existing ->
        # Link this insight to the existing principle if not already linked
        ensure_derivation(existing, insight)
        {:ok, :skipped_exact}

      nil ->
        # Step 2: Semantic dedup — check embedding similarity
        check_semantic_and_create(insight, content_hash)
    end
  end

  defp check_semantic_and_create(insight, content_hash) do
    embedding = get_embedding(insight)

    case find_semantic_duplicate(embedding) do
      {:match, existing} ->
        ensure_derivation(existing, insight)
        {:ok, :skipped_semantic}

      :no_match ->
        create_principle(insight, content_hash, embedding)
    end
  end

  defp find_semantic_duplicate(nil), do: :no_match

  defp find_semantic_duplicate(embedding) do
    embedding_literal = Pgvector.new(embedding)

    results =
      from(p in Principle,
        where: not is_nil(p.embedding),
        where: p.status in [:active, :decaying],
        select: {p, fragment("1 - (? <=> ?)", p.embedding, ^embedding_literal)},
        order_by: fragment("? <=> ?", p.embedding, ^embedding_literal),
        limit: 1
      )
      |> Repo.all()
      |> Enum.filter(fn {_p, sim} -> sim >= 0.92 end)

    case results do
      [{principle, _sim} | _] -> {:match, principle}
      [] -> :no_match
    end
  end

  defp create_principle(insight, content_hash, embedding) do
    category = Map.get(@category_map, insight.category, :learning)
    domain = if insight.domain, do: [insight.domain], else: []

    rank = Principle.compute_rank(%{
      confidence: insight.confidence,
      frequency: insight.observation_count,
      recency_score: 1.0,
      source_quality: 0.5
    })

    attrs = %{
      content: insight.content,
      content_hash: content_hash,
      embedding: embedding,
      category: category,
      tags: insight.tags || [],
      domains: domain,
      confidence: insight.confidence,
      frequency: insight.observation_count,
      recency_score: 1.0,
      source_quality: 0.5,
      rank: rank,
      status: :active
    }

    Repo.transaction(fn ->
      {:ok, principle} =
        %Principle{}
        |> Principle.changeset(attrs)
        |> Repo.insert()

      {:ok, _derivation} =
        %Derivation{}
        |> Derivation.changeset(%{
          principle_id: principle.id,
          insight_id: insight.id,
          contribution_weight: 1.0
        })
        |> Repo.insert()

      principle
    end)
    |> case do
      {:ok, _principle} -> {:ok, :promoted}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_derivation(%Principle{} = principle, %Insight{} = insight) do
    existing =
      from(d in Derivation,
        where: d.principle_id == ^principle.id and d.insight_id == ^insight.id
      )
      |> Repo.one()

    unless existing do
      %Derivation{}
      |> Derivation.changeset(%{
        principle_id: principle.id,
        insight_id: insight.id,
        contribution_weight: 1.0
      })
      |> Repo.insert()
    end
  end

  defp get_embedding(%Insight{embedding: nil}), do: nil

  defp get_embedding(%Insight{embedding: embedding}) when is_list(embedding), do: embedding

  defp get_embedding(%Insight{embedding: embedding}) do
    Pgvector.to_list(embedding)
  end
end
