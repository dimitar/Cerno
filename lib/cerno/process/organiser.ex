defmodule Cerno.Process.Organiser do
  @moduledoc """
  GenServer that runs the organisation process (Short-Term → Long-Term).

  Organisation steps:
  1. Promote eligible insights to principles (with exact + semantic dedup)
  2. Detect links between principles
  3. Lifecycle: decay recency, recompute ranks, prune stale principles
  """

  use GenServer
  require Logger

  alias Cerno.LongTerm.{Promoter, Linker, Lifecycle}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Trigger organisation."
  @spec organise() :: :ok
  def organise do
    GenServer.cast(__MODULE__, :organise)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(Cerno.PubSub, "reconciliation:complete")
    {:ok, %{running: false}}
  end

  @impl true
  def handle_cast(:organise, %{running: true} = state) do
    Logger.debug("Organisation already running, skipping")
    {:noreply, state}
  end

  @impl true
  def handle_cast(:organise, state) do
    state = %{state | running: true}

    Task.Supervisor.start_child(Cerno.Process.TaskSupervisor, fn ->
      run_organisation()
      GenServer.cast(__MODULE__, :done)
    end)

    {:noreply, state}
  end

  @impl true
  def handle_cast(:done, state) do
    {:noreply, %{state | running: false}}
  end

  @impl true
  def handle_info(:reconciliation_complete, state) do
    organise()
    {:noreply, state}
  end

  defp run_organisation do
    Logger.info("Starting organisation")

    # Step 1: Promote eligible insights to principles
    {:ok, promo_stats} = Promoter.promote_eligible()
    Logger.info("Promotion: #{promo_stats.promoted} promoted, #{promo_stats.skipped_exact} exact dupes, #{promo_stats.skipped_semantic} semantic dupes")

    # Step 2: Detect links between principles
    {:ok, link_count} = Linker.detect_links()
    Logger.info("Links: #{link_count} new links created")

    # Step 3: Lifecycle (decay + rank + prune)
    Lifecycle.run()

    Logger.info("Organisation complete")
  end
end
