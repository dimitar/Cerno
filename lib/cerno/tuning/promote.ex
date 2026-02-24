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
          insight_id: insight_id,
          eligible?: eligible?,
          checks: checks,
          nearest_threshold: nearest
        }
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
