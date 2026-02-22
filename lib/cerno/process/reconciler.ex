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
      run_reconciliation()
      GenServer.cast(__MODULE__, :done)
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
    # Phase 3 implementation: clustering, dedup, contradiction scan, confidence adjustment
    Logger.info("Reconciliation complete")
  end
end
