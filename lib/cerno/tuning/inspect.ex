defmodule Cerno.Tuning.Inspect do
  @moduledoc """
  Query functions for inspecting pipeline data.

  Returns raw data (maps, structs) — no IO, no formatting.
  """

  import Ecto.Query

  alias Cerno.Repo
  alias Cerno.ShortTerm.{Insight, Contradiction, Cluster}
  alias Cerno.LongTerm.{Principle, Derivation}

  # --- Stats ---

  @spec stats() :: map()
  def stats do
    %{
      insights: insight_stats(),
      principles: principle_stats(),
      contradictions: contradiction_stats(),
      clusters: %{total: Repo.aggregate(Cluster, :count)}
    }
  end

  defp insight_stats do
    %{
      total: Repo.aggregate(Insight, :count),
      by_status: group_count(Insight, :status),
      by_category: group_count(Insight, :category),
      top_domains: domain_counts(Insight, :domain)
    }
  end

  defp principle_stats do
    %{
      total: Repo.aggregate(Principle, :count),
      by_status: group_count(Principle, :status),
      by_category: group_count(Principle, :category)
    }
  end

  defp contradiction_stats do
    %{
      total: Repo.aggregate(Contradiction, :count),
      by_status: group_count(Contradiction, :resolution_status)
    }
  end

  defp group_count(schema, field) do
    from(s in schema,
      group_by: ^field,
      select: {field(s, ^field), count(s.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp domain_counts(schema, field) do
    from(s in schema,
      where: not is_nil(field(s, ^field)),
      group_by: ^field,
      select: {field(s, ^field), count(s.id)},
      order_by: [desc: count(s.id)],
      limit: 10
    )
    |> Repo.all()
    |> Map.new()
  end

  # --- List Insights ---

  @spec list_insights(keyword()) :: [%Insight{}]
  def list_insights(opts \\ []) do
    Insight
    |> maybe_filter_status(opts[:status])
    |> maybe_filter_category(opts[:category])
    |> maybe_filter_domain(opts[:domain])
    |> maybe_filter_min_confidence(opts[:min_confidence])
    |> maybe_filter_search(opts[:search])
    |> apply_sort(opts[:sort_by], :insight)
    |> limit_query(opts[:limit] || 20)
    |> Repo.all()
  end

  # --- List Principles ---

  @spec list_principles(keyword()) :: [%Principle{}]
  def list_principles(opts \\ []) do
    Principle
    |> maybe_filter_status(opts[:status])
    |> maybe_filter_category(opts[:category])
    |> maybe_filter_principle_domain(opts[:domain])
    |> maybe_filter_min_confidence(opts[:min_confidence])
    |> maybe_filter_search(opts[:search])
    |> apply_sort(opts[:sort_by], :principle)
    |> limit_query(opts[:limit] || 20)
    |> Repo.all()
  end

  # --- Get Insight ---

  @spec get_insight(integer()) :: {:ok, map()} | {:error, :not_found}
  def get_insight(id) do
    case Repo.get(Insight, id) do
      nil ->
        {:error, :not_found}

      insight ->
        insight =
          insight
          |> Repo.preload([:sources, :clusters, :contradictions_as_first, :contradictions_as_second])

        # Manually query derived principles via Derivation join
        derived_principles =
          from(p in Principle,
            join: d in Derivation,
            on: d.principle_id == p.id,
            where: d.insight_id == ^id
          )
          |> Repo.all()

        {:ok, Map.put(insight, :derived_principles, derived_principles)}
    end
  end

  # --- Get Principle ---

  @spec get_principle(integer()) :: {:ok, map()} | {:error, :not_found}
  def get_principle(id) do
    case Repo.get(Principle, id) do
      nil ->
        {:error, :not_found}

      principle ->
        principle =
          principle
          |> Repo.preload([
            derivations: :insight,
            links_as_source: :target,
            links_as_target: :source
          ])

        link_count = length(principle.links_as_source) + length(principle.links_as_target)

        config = Application.get_env(:cerno, :ranking, [])
        cw = Keyword.get(config, :confidence_weight, 0.35)
        fw = Keyword.get(config, :frequency_weight, 0.25)
        rw = Keyword.get(config, :recency_weight, 0.20)
        qw = Keyword.get(config, :quality_weight, 0.15)
        lw = Keyword.get(config, :links_weight, 0.05)

        freq_normalized = min(:math.log(1 + principle.frequency) / :math.log(150), 1.0)
        link_normalized = min(link_count / 20, 1.0)

        rank_breakdown = %{
          confidence: cw * principle.confidence,
          frequency: fw * freq_normalized,
          recency: rw * principle.recency_score,
          quality: qw * principle.source_quality,
          links: lw * link_normalized
        }

        {:ok, Map.put(principle, :rank_breakdown, rank_breakdown)}
    end
  end

  # --- List Fragments ---

  @spec list_fragments(String.t()) :: {:ok, [Cerno.Atomic.Fragment.t()]} | {:error, term()}
  def list_fragments(path) do
    Cerno.Atomic.Parser.parse(path)
  end

  # --- Private filter helpers ---

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, status), do: from(q in query, where: q.status == ^status)

  defp maybe_filter_category(query, nil), do: query
  defp maybe_filter_category(query, cat), do: from(q in query, where: q.category == ^cat)

  defp maybe_filter_domain(query, nil), do: query
  defp maybe_filter_domain(query, domain), do: from(q in query, where: q.domain == ^domain)

  defp maybe_filter_principle_domain(query, nil), do: query
  defp maybe_filter_principle_domain(query, domain) do
    from(q in query, where: ^domain in q.domains)
  end

  defp maybe_filter_min_confidence(query, nil), do: query
  defp maybe_filter_min_confidence(query, min) do
    from(q in query, where: q.confidence >= ^min)
  end

  defp maybe_filter_search(query, nil), do: query
  defp maybe_filter_search(query, search) do
    pattern = "%#{search}%"
    from(q in query, where: ilike(q.content, ^pattern))
  end

  defp apply_sort(query, nil, _type), do: from(q in query, order_by: [desc: q.inserted_at])
  defp apply_sort(query, :confidence, _type), do: from(q in query, order_by: [desc: q.confidence])
  defp apply_sort(query, :inserted_at, _type), do: from(q in query, order_by: [desc: q.inserted_at])
  defp apply_sort(query, :observation_count, :insight), do: from(q in query, order_by: [desc: q.observation_count])
  defp apply_sort(query, :rank, :principle), do: from(q in query, order_by: [desc: q.rank])
  defp apply_sort(query, :frequency, :principle), do: from(q in query, order_by: [desc: q.frequency])
  defp apply_sort(query, _, _type), do: from(q in query, order_by: [desc: q.inserted_at])

  defp limit_query(query, limit), do: from(q in query, limit: ^limit)
end
