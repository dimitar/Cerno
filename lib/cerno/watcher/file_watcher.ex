defmodule Cerno.Watcher.FileWatcher do
  @moduledoc """
  GenServer that polls a watched project directory for context file changes.

  Started dynamically under `Cerno.Watcher.Supervisor` (DynamicSupervisor).
  Periodically scans the project path using registered parsers' file patterns,
  hashes each file, and broadcasts `{:file_changed, path}` on the
  `file:changed` PubSub topic when a file's content has changed.

  ## Usage

      Cerno.Watcher.FileWatcher.start_watching("/path/to/project")
      Cerno.Watcher.FileWatcher.stop_watching("/path/to/project")
  """

  use GenServer
  require Logger

  alias Cerno.Atomic.Parser

  @default_interval_ms 30_000

  # --- Public API ---

  @doc "Start watching a project directory for context file changes."
  @spec start_watching(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_watching(project_path, opts \\ []) do
    DynamicSupervisor.start_child(
      Cerno.Watcher.Supervisor,
      {__MODULE__, Keyword.merge(opts, path: project_path)}
    )
  end

  @doc "Stop watching a project directory."
  @spec stop_watching(String.t()) :: :ok | {:error, :not_found}
  def stop_watching(project_path) do
    case Registry.lookup(Cerno.Watcher.Registry, project_path) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(Cerno.Watcher.Supervisor, pid)

      [] ->
        {:error, :not_found}
    end
  end

  @doc "List all currently watched project paths."
  @spec list_watched() :: [String.t()]
  def list_watched do
    Registry.select(Cerno.Watcher.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  def start_link(opts) do
    path = Keyword.fetch!(opts, :path)
    GenServer.start_link(__MODULE__, opts, name: via(path))
  end

  def child_spec(opts) do
    path = Keyword.fetch!(opts, :path)

    %{
      id: {__MODULE__, path},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  # --- Server callbacks ---

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    interval = Keyword.get(opts, :interval_ms, @default_interval_ms)

    Logger.info("FileWatcher started for #{path} (interval: #{interval}ms)")

    # Initial scan captures baseline hashes without broadcasting
    initial_hashes = hash_context_files(path)

    schedule_poll(interval)

    {:ok, %{path: path, interval: interval, file_hashes: initial_hashes}}
  end

  @impl true
  def handle_info(:poll, state) do
    new_hashes = hash_context_files(state.path)

    changed_files =
      new_hashes
      |> Enum.filter(fn {file_path, hash} ->
        Map.get(state.file_hashes, file_path) != hash
      end)
      |> Enum.map(fn {file_path, _hash} -> file_path end)

    Enum.each(changed_files, fn file_path ->
      Logger.info("FileWatcher detected change: #{file_path}")

      Phoenix.PubSub.broadcast(
        Cerno.PubSub,
        "file:changed",
        {:file_changed, file_path}
      )
    end)

    schedule_poll(state.interval)
    {:noreply, %{state | file_hashes: new_hashes}}
  end

  # --- Internal ---

  defp via(path) do
    {:via, Registry, {Cerno.Watcher.Registry, path}}
  end

  defp schedule_poll(interval) do
    Process.send_after(self(), :poll, interval)
  end

  defp hash_context_files(project_path) do
    find_context_files(project_path)
    |> Enum.reduce(%{}, fn file_path, acc ->
      case File.read(file_path) do
        {:ok, content} -> Map.put(acc, file_path, Parser.hash_file(content))
        {:error, _} -> acc
      end
    end)
  end

  defp find_context_files(project_path) do
    Parser.registered_patterns()
    |> Enum.flat_map(fn pattern ->
      Path.join(project_path, "**/" <> pattern)
      |> String.replace("\\", "/")
      |> Path.wildcard()
    end)
  end
end
