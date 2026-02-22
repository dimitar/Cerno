defmodule Cerno.ShortTerm.Confidence do
  @moduledoc """
  Confidence adjustment engine for Insights.

  Recomputes the `confidence` field on all active insights by applying
  a series of adjustments:

    1. **Multi-project boost** — insights observed across multiple projects
       gain `+0.05` per additional project (capped at 1.0).
    2. **Stale decay** — insights not seen for more than 90 days are
       multiplied by 0.9.
    3. **Contradiction penalty** — insights with unresolved contradictions
       are multiplied by 0.8.
    4. **Observation floor** — frequently-observed insights are guaranteed
       a minimum confidence proportional to `log(1 + observation_count)`.

  The final value is always clamped to `[0.0, 1.0]`.
  """

  import Ecto.Query

  alias Cerno.Repo
  alias Cerno.ShortTerm.{Insight, InsightSource, Contradiction}

  require Logger

  @stale_days 90
  @stale_decay 0.9
  @contradiction_penalty 0.8
  @multi_project_boost 0.05
  @observation_floor_max 0.6
  @observation_floor_log_base 50

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Recompute and persist confidence for every active insight.

  Returns `{:ok, count}` where `count` is the number of insights adjusted.
  """
  @spec adjust_all() :: {:ok, non_neg_integer()}
  def adjust_all do
    insights =
      from(i in Insight, where: i.status == :active)
      |> Repo.all()

    count =
      insights
      |> Enum.map(fn insight ->
        new_confidence = compute_adjusted_confidence(insight)

        insight
        |> Insight.changeset(%{confidence: new_confidence})
        |> Repo.update!()
      end)
      |> length()

    Logger.info("Confidence adjustment complete: #{count} insights adjusted")

    {:ok, count}
  end

  @doc """
  Compute the adjusted confidence for a single insight.

  Applies multi-project boost, stale decay, contradiction penalty,
  and observation floor in sequence, then clamps to `[0.0, 1.0]`.
  """
  @spec compute_adjusted_confidence(%Insight{}) :: float()
  def compute_adjusted_confidence(%Insight{} = insight) do
    insight.confidence
    |> apply_multi_project_boost(insight)
    |> apply_stale_decay(insight)
    |> apply_contradiction_penalty(insight)
    |> apply_observation_floor(insight)
    |> clamp(0.0, 1.0)
  end

  @doc """
  Return the number of distinct projects that contributed to an insight.

  Always returns at least 1.
  """
  @spec distinct_project_count(%Insight{}) :: pos_integer()
  def distinct_project_count(%Insight{id: id}) do
    count =
      from(s in InsightSource,
        where: s.insight_id == ^id,
        select: count(s.source_project, :distinct)
      )
      |> Repo.one()

    max(count, 1)
  end

  @doc """
  Check whether an insight has any unresolved contradictions.
  """
  @spec has_unresolved_contradictions?(%Insight{}) :: boolean()
  def has_unresolved_contradictions?(%Insight{id: id}) do
    from(c in Contradiction,
      where:
        (c.insight_a_id == ^id or c.insight_b_id == ^id) and
          c.resolution_status == :unresolved
    )
    |> Repo.exists?()
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp apply_multi_project_boost(confidence, insight) do
    projects = distinct_project_count(insight)
    boost = @multi_project_boost * (projects - 1)
    min(confidence + boost, 1.0)
  end

  defp apply_stale_decay(confidence, insight) do
    case insight.last_seen_at do
      nil ->
        confidence

      last_seen ->
        days_since = DateTime.diff(DateTime.utc_now(), last_seen, :day)

        if days_since > @stale_days do
          confidence * @stale_decay
        else
          confidence
        end
    end
  end

  defp apply_contradiction_penalty(confidence, insight) do
    if has_unresolved_contradictions?(insight) do
      confidence * @contradiction_penalty
    else
      confidence
    end
  end

  defp apply_observation_floor(confidence, insight) do
    floor =
      min(
        :math.log(1 + insight.observation_count) / :math.log(@observation_floor_log_base),
        @observation_floor_max
      )

    max(confidence, floor)
  end

  defp clamp(value, min_val, max_val) do
    value
    |> max(min_val)
    |> min(max_val)
  end
end
