defmodule Cerno.LongTerm.Linker do
  @moduledoc """
  Detects and creates typed links between Principles.

  For each active principle, finds others with embedding similarity > 0.5
  and classifies the relationship:

  - > 0.85 → `:reinforces`
  - 0.7–0.85 + same domain → `:related`
  - 0.5–0.7 + negation heuristic → `:contradicts`
  - shared tags + different domains → `:generalizes` / `:specializes`

  Skips pairs that already have a link of the same type.
  """

  import Ecto.Query
  require Logger

  alias Cerno.Repo
  alias Cerno.LongTerm.{Principle, PrincipleLink}

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
  Detect and persist links between all active principles.

  Returns `{:ok, count}` of links created.
  """
  @spec detect_links() :: {:ok, non_neg_integer()}
  def detect_links do
    principles =
      from(p in Principle,
        where: p.status in [:active, :decaying],
        where: not is_nil(p.embedding)
      )
      |> Repo.all()

    Logger.info("Link detection: scanning #{length(principles)} principles")

    count =
      Enum.reduce(principles, 0, fn principle, total ->
        similar = find_similar_principles(principle)

        links_created =
          Enum.reduce(similar, 0, fn {other, similarity}, acc ->
            case classify_and_create(principle, other, similarity) do
              :created -> acc + 1
              :exists -> acc
            end
          end)

        total + links_created
      end)

    Logger.info("Link detection complete: #{count} links created")
    {:ok, count}
  end

  defp find_similar_principles(%Principle{} = principle) do
    embedding = to_list(principle.embedding)
    embedding_literal = Pgvector.new(embedding)

    from(p in Principle,
      where: p.id != ^principle.id,
      where: p.status in [:active, :decaying],
      where: not is_nil(p.embedding),
      select: {p, fragment("1 - (? <=> ?)", p.embedding, ^embedding_literal)},
      order_by: fragment("? <=> ?", p.embedding, ^embedding_literal),
      limit: 20
    )
    |> Repo.all()
    |> Enum.filter(fn {_p, sim} -> sim > 0.5 end)
  end

  defp classify_and_create(source, target, similarity) do
    link_type = classify_link(source, target, similarity)

    # Normalize direction: lower ID is always source
    {src, tgt} =
      if source.id < target.id,
        do: {source, target},
        else: {target, source}

    # Check if link already exists
    existing =
      from(l in PrincipleLink,
        where: l.source_id == ^src.id and l.target_id == ^tgt.id and l.link_type == ^link_type
      )
      |> Repo.one()

    if existing do
      :exists
    else
      case %PrincipleLink{}
           |> PrincipleLink.changeset(%{
             source_id: src.id,
             target_id: tgt.id,
             link_type: link_type,
             strength: similarity
           })
           |> Repo.insert() do
        {:ok, _} -> :created
        {:error, _} -> :exists
      end
    end
  end

  defp classify_link(a, b, similarity) do
    cond do
      similarity > 0.85 ->
        :reinforces

      similarity >= 0.7 and domains_overlap?(a, b) ->
        :related

      similarity >= 0.5 and similarity < 0.7 and has_negation?(a.content, b.content) ->
        :contradicts

      tags_overlap?(a, b) and not domains_overlap?(a, b) ->
        if length(a.domains) > length(b.domains), do: :generalizes, else: :specializes

      true ->
        :related
    end
  end

  defp domains_overlap?(a, b) do
    a_set = MapSet.new(a.domains || [])
    b_set = MapSet.new(b.domains || [])
    not MapSet.disjoint?(a_set, b_set)
  end

  defp tags_overlap?(a, b) do
    a_set = MapSet.new(a.tags || [])
    b_set = MapSet.new(b.tags || [])
    not MapSet.disjoint?(a_set, b_set)
  end

  defp has_negation?(content_a, content_b) do
    a_lower = String.downcase(content_a)
    b_lower = String.downcase(content_b)

    Enum.any?(@negation_pairs, fn {pos, neg} ->
      (String.contains?(a_lower, pos) and String.contains?(b_lower, neg)) or
        (String.contains?(a_lower, neg) and String.contains?(b_lower, pos))
    end)
  end

  defp to_list(embedding) when is_list(embedding), do: embedding
  defp to_list(%Pgvector{} = vec), do: Pgvector.to_list(vec)
  defp to_list(embedding) when is_struct(embedding), do: Pgvector.to_list(embedding)
end
