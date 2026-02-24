defmodule Cerno.Tuning.Promote do
  @moduledoc """
  Promotion eligibility analysis for insights.

  Decomposes the promotion criteria from `Cerno.Process.Reconciler.promotion_candidates/0`
  into per-check analysis, showing pass/fail, actual vs required values, and the
  nearest failing threshold (most actionable next step).
  """

  import Ecto.Query

  alias Cerno.Repo
  alias Cerno.ShortTerm.{Insight, Contradiction}
  alias Cerno.LongTerm.Derivation

  @type check :: %{
          name: atom(),
          pass?: boolean(),
          actual: term(),
          required: term(),
          gap_pct: float() | nil
        }

  @type eligibility_result :: %{
          insight_id: integer(),
          eligible?: boolean(),
          checks: [check()],
          nearest_threshold: check() | nil
        }

  @doc """
  Explains promotion eligibility for a given insight.

  Returns a map with pass/fail per criterion, actual vs required values,
  and the `nearest_threshold` — the failing check closest to passing.

  Returns `{:error, :not_found}` if the insight doesn't exist.
  """
  @spec explain_eligibility(integer()) :: eligibility_result() | {:error, :not_found}
  def explain_eligibility(insight_id) do
    case Repo.get(Insight, insight_id) do
      nil ->
        {:error, :not_found}

      insight ->
        build_eligibility(insight)
    end
  end

  @doc """
  Returns a summary grouping all active insights by their promotion blocking reason.

  Each insight appears in exactly one group, determined by priority order:
  `already_promoted > contradictions > confidence > observations > age`.

  Insights that pass all checks appear in the `:eligible` group.

  Returns a map with:
  - `total_active` — count of all active insights
  - `eligible` — list of `%{insight: insight, eligibility: eligibility}`
  - `blocked_by_confidence` — insights failing the confidence check
  - `blocked_by_observations` — insights failing the observations check
  - `blocked_by_age` — insights failing the age check
  - `blocked_by_contradictions` — insights failing the no_contradictions check
  - `already_promoted` — insights that have already been promoted
  """
  @spec promotion_summary() :: %{
          total_active: integer(),
          eligible: [%{insight: Insight.t(), eligibility: eligibility_result()}],
          blocked_by_confidence: [%{insight: Insight.t(), eligibility: eligibility_result()}],
          blocked_by_observations: [%{insight: Insight.t(), eligibility: eligibility_result()}],
          blocked_by_age: [%{insight: Insight.t(), eligibility: eligibility_result()}],
          blocked_by_contradictions: [%{insight: Insight.t(), eligibility: eligibility_result()}],
          already_promoted: [%{insight: Insight.t(), eligibility: eligibility_result()}]
        }
  def promotion_summary do
    insights = Repo.all(from(i in Insight, where: i.status == :active))

    entries =
      Enum.map(insights, fn insight ->
        eligibility = build_eligibility(insight)
        %{insight: insight, eligibility: eligibility}
      end)

    empty = %{
      total_active: length(insights),
      eligible: [],
      blocked_by_confidence: [],
      blocked_by_observations: [],
      blocked_by_age: [],
      blocked_by_contradictions: [],
      already_promoted: []
    }

    Enum.reduce(entries, empty, fn entry, acc ->
      group = classify_blocking_reason(entry.eligibility)
      Map.update!(acc, group, &[entry | &1])
    end)
  end

  # --- Private: eligibility builder ---

  defp build_eligibility(insight) do
    config = Application.get_env(:cerno, :promotion, [])
    min_confidence = Keyword.get(config, :min_confidence, 0.7)
    min_observations = Keyword.get(config, :min_observations, 3)
    min_age_days = Keyword.get(config, :min_age_days, 7)

    checks = [
      check_confidence(insight, min_confidence),
      check_observations(insight, min_observations),
      check_age(insight, min_age_days),
      check_no_contradictions(insight),
      check_not_already_promoted(insight)
    ]

    eligible? = Enum.all?(checks, & &1.pass?)
    nearest = find_nearest_threshold(checks)

    %{
      insight_id: insight.id,
      eligible?: eligible?,
      checks: checks,
      nearest_threshold: nearest
    }
  end

  # Priority order: already_promoted > contradictions > confidence > observations > age
  defp classify_blocking_reason(%{eligible?: true}), do: :eligible

  defp classify_blocking_reason(%{checks: checks}) do
    cond do
      check_fails?(checks, :not_already_promoted) -> :already_promoted
      check_fails?(checks, :no_contradictions) -> :blocked_by_contradictions
      check_fails?(checks, :confidence) -> :blocked_by_confidence
      check_fails?(checks, :observations) -> :blocked_by_observations
      check_fails?(checks, :age) -> :blocked_by_age
    end
  end

  defp check_fails?(checks, name) do
    case Enum.find(checks, &(&1.name == name)) do
      nil -> false
      check -> not check.pass?
    end
  end

  # --- Individual checks ---

  defp check_confidence(insight, min_confidence) do
    pass? = insight.confidence >= min_confidence

    %{
      name: :confidence,
      pass?: pass?,
      actual: insight.confidence,
      required: min_confidence,
      gap_pct: gap_pct(insight.confidence, min_confidence, pass?)
    }
  end

  defp check_observations(insight, min_observations) do
    pass? = insight.observation_count >= min_observations

    %{
      name: :observations,
      pass?: pass?,
      actual: insight.observation_count,
      required: min_observations,
      gap_pct: gap_pct(insight.observation_count, min_observations, pass?)
    }
  end

  defp check_age(insight, min_age_days) do
    now = DateTime.utc_now()
    age_seconds = DateTime.diff(now, insight.inserted_at, :second)
    age_days = age_seconds / 86_400.0

    pass? = age_days >= min_age_days

    %{
      name: :age,
      pass?: pass?,
      actual: age_days,
      required: min_age_days,
      gap_pct: gap_pct(age_days, min_age_days, pass?)
    }
  end

  defp check_no_contradictions(insight) do
    count =
      from(c in Contradiction,
        where: c.resolution_status == :unresolved,
        where: c.insight_a_id == ^insight.id or c.insight_b_id == ^insight.id,
        select: count(c.id)
      )
      |> Repo.one()

    %{
      name: :no_contradictions,
      pass?: count == 0,
      actual: count,
      required: 0
    }
  end

  defp check_not_already_promoted(insight) do
    promoted? =
      from(d in Derivation,
        where: d.insight_id == ^insight.id,
        select: count(d.id)
      )
      |> Repo.one()
      |> Kernel.>(0)

    %{
      name: :not_already_promoted,
      pass?: not promoted?,
      actual: promoted?,
      required: false
    }
  end

  # --- Helpers ---

  defp gap_pct(_actual, _required, true = _pass?), do: 0.0

  defp gap_pct(_actual, 0, false = _pass?), do: 1.0

  defp gap_pct(actual, required, false = _pass?) do
    (required - actual) / required
  end

  defp find_nearest_threshold(checks) do
    checks
    |> Enum.filter(fn check -> not check.pass? and Map.has_key?(check, :gap_pct) end)
    |> case do
      [] -> nil
      failing -> Enum.min_by(failing, & &1.gap_pct)
    end
  end
end
