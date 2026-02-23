defmodule Cerno.Process.Reconciler do
  @moduledoc """
  GenServer that runs the reconciliation process on the short-term layer.

  Reconciliation steps:
  1. Re-cluster all active insights
  2. Intra-cluster deduplication (lower threshold)
  3. Cross-cluster contradiction scan
  4. Confidence adjustment (multi-project ↑, stale ↓, contradicted ↓)
  5. Flag promotion candidates
  """

  use GenServer
  require Logger

  import Ecto.Query
  alias Cerno.Repo
  alias Cerno.ShortTerm.{Clusterer, Confidence, Insight}
  alias Cerno.LongTerm.Derivation

  @max_promotion_candidates 10_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Trigger reconciliation."
  @spec reconcile() :: :ok
  def reconcile do
    GenServer.cast(__MODULE__, :reconcile)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(Cerno.PubSub, "accumulation:complete")
    {:ok, %{running: false}}
  end

  @impl true
  def handle_cast(:reconcile, %{running: true} = state) do
    Logger.debug("Reconciliation already running, skipping")
    {:noreply, state}
  end

  @impl true
  def handle_cast(:reconcile, state) do
    state = %{state | running: true}

    Task.Supervisor.start_child(Cerno.Process.TaskSupervisor, fn ->
      try do
        run_reconciliation()
      rescue
        e -> Logger.error("Reconciliation failed: #{inspect(e)}")
      after
        GenServer.cast(__MODULE__, :done)
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_cast(:done, state) do
    Phoenix.PubSub.broadcast(
      Cerno.PubSub,
      "reconciliation:complete",
      :reconciliation_complete
    )

    {:noreply, %{state | running: false}}
  end

  @impl true
  def handle_info({:accumulation_complete, _path}, state) do
    reconcile()
    {:noreply, state}
  end

  defp run_reconciliation do
    Logger.info("Starting reconciliation")

    # Step 1: Cluster all active insights
    cluster_maps = Clusterer.cluster_insights()
    Logger.info("Found #{length(cluster_maps)} clusters")

    # Step 2: Intra-cluster deduplication
    {:ok, dedup_stats} = Clusterer.dedup_within_clusters(cluster_maps)
    Logger.info("Dedup: #{dedup_stats.merged} merged, #{dedup_stats.superseded} superseded")

    # Step 3: Persist clusters
    # Re-cluster after dedup since some insights may have been superseded
    cluster_maps = Clusterer.cluster_insights()
    {:ok, cluster_count} = Clusterer.persist_clusters(cluster_maps)
    Logger.info("Persisted #{cluster_count} clusters")

    # Step 4: Cross-cluster contradiction scan
    {:ok, contradiction_count} = Clusterer.scan_cross_cluster_contradictions(cluster_maps)
    Logger.info("Found #{contradiction_count} new contradictions")

    # Step 5: Confidence adjustment
    {:ok, adjusted_count} = Confidence.adjust_all()
    Logger.info("Adjusted confidence for #{adjusted_count} insights")

    # Step 6: Log promotion candidates (actual promotion done by Organiser)
    candidates = promotion_candidates()
    Logger.info("#{length(candidates)} promotion candidates identified")

    Logger.info("Reconciliation complete")
  end

  @doc """
  Query insights that meet promotion criteria.

  Criteria (from config):
  - confidence > min_confidence
  - observation_count >= min_observations
  - age > min_age_days
  - no unresolved contradictions
  - not already promoted (no Derivation record)
  """
  @spec promotion_candidates() :: [%Insight{}]
  def promotion_candidates do
    config = Application.get_env(:cerno, :promotion, [])
    min_confidence = Keyword.get(config, :min_confidence, 0.7)
    min_observations = Keyword.get(config, :min_observations, 3)
    min_age_days = Keyword.get(config, :min_age_days, 7)

    min_age_date = DateTime.add(DateTime.utc_now(), -min_age_days, :day)

    from(i in Insight,
      where: i.status == :active,
      where: i.confidence >= ^min_confidence,
      where: i.observation_count >= ^min_observations,
      where: i.inserted_at <= ^min_age_date,
      where:
        i.id not in subquery(
          from(d in Derivation, select: d.insight_id)
        ),
      where:
        i.id not in subquery(
          from(c in Cerno.ShortTerm.Contradiction,
            where: c.resolution_status == :unresolved,
            select: c.insight_a_id
          )
        ),
      where:
        i.id not in subquery(
          from(c in Cerno.ShortTerm.Contradiction,
            where: c.resolution_status == :unresolved,
            select: c.insight_b_id
          )
        ),
      limit: ^@max_promotion_candidates
    )
    |> Repo.all()
  end
end
