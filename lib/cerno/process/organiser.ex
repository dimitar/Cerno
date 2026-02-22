defmodule Cerno.Process.Organiser do
  @moduledoc """
  GenServer that runs the organisation process (Short-Term → Long-Term).

  Organisation steps:
  1. Distil: single insight promotes directly; clusters get LLM-synthesized
  2. Dedup against existing principles (hash then embedding)
  3. Link detection and classification
  4. Rank computation
  5. Pruning: active → decaying → pruned lifecycle
  """

  use GenServer
  require Logger

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
    # Phase 4 implementation: promotion, dedup, linking, ranking, pruning
    Logger.info("Organisation complete")
  end
end
