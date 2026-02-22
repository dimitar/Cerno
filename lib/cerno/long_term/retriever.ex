defmodule Cerno.LongTerm.Retriever do
  @moduledoc """
  Retrieves relevant principles for a target file.

  Uses hybrid scoring: semantic similarity + rank + domain match.
  Configurable via `:cerno, :resolution`.
  """

  import Ecto.Query
  require Logger

  alias Cerno.LongTerm.Principle
  alias Cerno.ShortTerm.{Classifier, Clusterer}
  alias Cerno.Repo

  @max_content_chars 8000

  @doc """
  Retrieve principles relevant to the given file content.

  Returns `{:ok, [{principle, hybrid_score}]}` sorted by score descending,
  filtered by min_hybrid_score and capped at max_principles.

  Falls back to rank-only scoring if embedding fails.
  """
  @spec retrieve_for_file(String.t(), keyword()) :: {:ok, [{%Principle{}, float()}]}
  def retrieve_for_file(content, opts \\ []) do
    config = resolution_config()
    max_principles = Keyword.get(opts, :max_principles, config[:max_principles])
    min_score = Keyword.get(opts, :min_hybrid_score, config[:min_hybrid_score])

    file_domains = detect_file_domains(content)
    truncated = String.slice(content, 0, @max_content_chars)

    provider = Application.get_env(:cerno, :embedding)[:provider]

    case provider.embed(truncated) do
      {:ok, embedding} ->
        scored = score_principles_hybrid(embedding, file_domains, config)

        results =
          scored
          |> Enum.filter(fn {_p, score} -> score >= min_score end)
          |> Enum.sort_by(fn {_p, score} -> score end, :desc)
          |> Enum.take(max_principles)

        {:ok, results}

      {:error, reason} ->
        Logger.warning("Embedding failed (#{inspect(reason)}), falling back to rank-only retrieval")
        {:ok, retrieve_by_rank_only(file_domains, max_principles, min_score, config)}
    end
  end

  @doc """
  Detect the most relevant domains for file content.

  Splits content into paragraphs, classifies each via the heuristic Classifier,
  and returns the top 3 domains by frequency.
  """
  @spec detect_file_domains(String.t()) :: [String.t()]
  def detect_file_domains(content) do
    content
    |> String.split(~r/(\r?\n){2,}/)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.map(fn paragraph ->
      classification = Classifier.classify(paragraph)
      classification.domain
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_domain, count} -> count end, :desc)
    |> Enum.take(3)
    |> Enum.map(fn {domain, _count} -> domain end)
  end

  @negation_pairs [
    {"always", "never"},
    {"do", "don't"},
    {"use", "avoid"},
    {"should", "should not"},
    {"prefer", "avoid"},
    {"must", "must not"},
    {"enable", "disable"}
  ]

  @doc """
  Filter out principles already represented in the file content.

  For each principle, compares its embedding against section embeddings:
  - Similarity >= threshold → filtered out (already represented)
  - Similarity in 0.5–0.7 + negation heuristic → kept but marked as conflict

  Returns `{kept, conflicts}` where conflicts are `{principle, :conflict}` tuples.
  """
  @spec filter_already_represented([{%Principle{}, float()}], [[float()]], keyword()) ::
          {[{%Principle{}, float()}], [{%Principle{}, float()}]}
  def filter_already_represented(scored_principles, section_embeddings, opts \\ []) do
    config = resolution_config()
    threshold = Keyword.get(opts, :already_represented_threshold, config[:already_represented_threshold])

    {kept, conflicts} =
      Enum.reduce(scored_principles, {[], []}, fn {principle, score}, {kept_acc, conflict_acc} ->
        principle_emb = to_list(principle.embedding)

        if is_nil(principle_emb) do
          {[{principle, score} | kept_acc], conflict_acc}
        else
          max_similarity = max_section_similarity(principle_emb, section_embeddings)

          cond do
            max_similarity >= threshold ->
              # Already represented — filter out
              {kept_acc, conflict_acc}

            is_conflict?(principle, section_embeddings) ->
              {kept_acc, [{principle, score} | conflict_acc]}

            true ->
              {[{principle, score} | kept_acc], conflict_acc}
          end
        end
      end)

    {Enum.reverse(kept), Enum.reverse(conflicts)}
  end

  @doc """
  Embed file sections for already-represented filtering.

  Splits content by H2 headings (or double newlines), embeds each section.
  Returns list of embedding vectors.
  """
  @spec embed_file_sections(String.t()) :: {:ok, [[float()]]} | {:error, term()}
  def embed_file_sections(content) do
    sections =
      content
      |> String.split(~r/(\r?\n)(?=## )/)
      |> Enum.reject(&(String.trim(&1) == ""))

    if Enum.empty?(sections) do
      {:ok, []}
    else
      provider = Application.get_env(:cerno, :embedding)[:provider]

      truncated = Enum.map(sections, &String.slice(&1, 0, @max_content_chars))

      case provider.embed_batch(truncated) do
        {:ok, embeddings} -> {:ok, embeddings}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # --- Private ---

  defp max_section_similarity(_principle_emb, []), do: 0.0

  defp max_section_similarity(principle_emb, section_embeddings) do
    section_embeddings
    |> Enum.map(&Clusterer.cosine_similarity(principle_emb, &1))
    |> Enum.max()
  end

  defp is_conflict?(principle, section_embeddings) do
    principle_emb = to_list(principle.embedding)
    principle_lower = String.downcase(principle.content)

    Enum.any?(section_embeddings, fn section_emb ->
      sim = Clusterer.cosine_similarity(principle_emb, section_emb)

      sim >= 0.5 and sim <= 0.7 and has_negation?(principle_lower)
    end)
  end

  defp has_negation?(text) do
    Enum.any?(@negation_pairs, fn {pos, neg} ->
      String.contains?(text, pos) or String.contains?(text, neg)
    end)
  end

  defp to_list(nil), do: nil
  defp to_list(embedding) when is_list(embedding), do: embedding
  defp to_list(%Pgvector{} = vec), do: Pgvector.to_list(vec)

  defp to_list(embedding) do
    if is_struct(embedding), do: Pgvector.to_list(embedding), else: embedding
  end

  defp score_principles_hybrid(embedding, file_domains, config) do
    semantic_weight = config[:semantic_weight]
    rank_weight = config[:rank_weight]
    domain_weight = config[:domain_weight]

    embedding_literal = Pgvector.new(embedding)

    # Query active principles with semantic similarity
    principles_with_similarity =
      from(p in Principle,
        where: p.status == :active,
        where: not is_nil(p.embedding),
        select: {p, fragment("1 - (? <=> ?)", p.embedding, ^embedding_literal)},
        order_by: fragment("? <=> ?", p.embedding, ^embedding_literal),
        limit: 100
      )
      |> Repo.all()

    Enum.map(principles_with_similarity, fn {principle, similarity} ->
      domain_score = compute_domain_score(principle.domains, file_domains)

      hybrid =
        semantic_weight * max(similarity, 0.0) +
          rank_weight * principle.rank +
          domain_weight * domain_score

      {principle, hybrid}
    end)
  end

  defp retrieve_by_rank_only(file_domains, max_principles, min_score, config) do
    rank_weight = config[:rank_weight]
    domain_weight = config[:domain_weight]

    principles =
      from(p in Principle,
        where: p.status == :active,
        order_by: [desc: p.rank],
        limit: ^(max_principles * 2)
      )
      |> Repo.all()

    principles
    |> Enum.map(fn principle ->
      domain_score = compute_domain_score(principle.domains, file_domains)
      # Without semantic, redistribute weight to rank and domain
      total_weight = rank_weight + domain_weight
      hybrid = (rank_weight * principle.rank + domain_weight * domain_score) / max(total_weight, 0.01)
      {principle, hybrid}
    end)
    |> Enum.filter(fn {_p, score} -> score >= min_score end)
    |> Enum.sort_by(fn {_p, score} -> score end, :desc)
    |> Enum.take(max_principles)
  end

  defp compute_domain_score(principle_domains, file_domains) do
    if Enum.empty?(file_domains) or Enum.empty?(principle_domains) do
      0.0
    else
      matching = Enum.count(principle_domains, &(&1 in file_domains))
      matching / max(length(principle_domains), 1)
    end
  end

  defp resolution_config do
    defaults = [
      semantic_weight: 0.5,
      rank_weight: 0.3,
      domain_weight: 0.2,
      min_hybrid_score: 0.3,
      max_principles: 20,
      already_represented_threshold: 0.85
    ]

    config = Application.get_env(:cerno, :resolution, [])
    Keyword.merge(defaults, config)
  end
end
