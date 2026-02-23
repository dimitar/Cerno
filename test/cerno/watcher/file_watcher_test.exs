defmodule Cerno.Watcher.FileWatcherTest do
  use ExUnit.Case

  alias Cerno.Watcher.FileWatcher

  setup do
    # The watcher broadcasts file:changed, which triggers Accumulator → Reconciler → Organiser.
    # Those GenServers spawn Tasks that need DB access, so share the sandbox connection.
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Cerno.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Cerno.Repo, {:shared, self()})

    tmp_dir = Path.join(System.tmp_dir!(), "cerno_watcher_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(tmp_dir)
    File.write!(Path.join(tmp_dir, "CLAUDE.md"), "## Rules\n\nInitial content")

    on_exit(fn ->
      # Stop any watcher that might be running
      try do
        FileWatcher.stop_watching(tmp_dir)
      catch
        _, _ -> :ok
      end

      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  describe "start_watching/2" do
    test "starts a watcher for a project directory", %{tmp_dir: tmp_dir} do
      assert {:ok, pid} = FileWatcher.start_watching(tmp_dir, interval_ms: 60_000)
      assert Process.alive?(pid)
    end

    test "registers watcher in registry", %{tmp_dir: tmp_dir} do
      {:ok, _pid} = FileWatcher.start_watching(tmp_dir, interval_ms: 60_000)
      assert [tmp_dir] == FileWatcher.list_watched()
    end

    test "rejects duplicate watcher for same path", %{tmp_dir: tmp_dir} do
      {:ok, _pid} = FileWatcher.start_watching(tmp_dir, interval_ms: 60_000)
      assert {:error, {:already_started, _}} = FileWatcher.start_watching(tmp_dir, interval_ms: 60_000)
    end
  end

  describe "stop_watching/1" do
    test "stops an active watcher", %{tmp_dir: tmp_dir} do
      {:ok, pid} = FileWatcher.start_watching(tmp_dir, interval_ms: 60_000)
      assert :ok = FileWatcher.stop_watching(tmp_dir)
      refute Process.alive?(pid)
    end

    test "returns error for unknown path" do
      assert {:error, :not_found} = FileWatcher.stop_watching("/nonexistent/path")
    end
  end

  describe "list_watched/0" do
    test "lists all watched paths", %{tmp_dir: tmp_dir} do
      {:ok, _} = FileWatcher.start_watching(tmp_dir, interval_ms: 60_000)
      watched = FileWatcher.list_watched()
      assert tmp_dir in watched
    end

    test "returns empty list when nothing watched" do
      assert FileWatcher.list_watched() == []
    end
  end

  describe "change detection" do
    test "broadcasts file:changed on modification", %{tmp_dir: tmp_dir} do
      Phoenix.PubSub.subscribe(Cerno.PubSub, "file:changed")

      # Start watcher with short interval
      {:ok, _pid} = FileWatcher.start_watching(tmp_dir, interval_ms: 100)

      # Wait for initial scan to complete
      Process.sleep(200)

      # Modify the file
      File.write!(Path.join(tmp_dir, "CLAUDE.md"), "## Rules\n\nModified content")

      # Wait for poll to detect change
      assert_receive {:file_changed, _path}, 1000

      # Stop the watcher immediately so no more file:changed events fire
      FileWatcher.stop_watching(tmp_dir)

      # The file:changed event triggers Accumulator → Reconciler → Organiser via PubSub.
      # PubSub.broadcast is synchronous, so by the time assert_receive succeeds above,
      # the Accumulator's mailbox already has the :accumulate cast. :sys.get_state acts
      # as a mailbox barrier, so polling will correctly see the in-progress state.
      wait_for_pipeline()
    end

    test "does not broadcast when file unchanged", %{tmp_dir: tmp_dir} do
      Phoenix.PubSub.subscribe(Cerno.PubSub, "file:changed")

      {:ok, _pid} = FileWatcher.start_watching(tmp_dir, interval_ms: 100)

      # Wait for two polls without changing anything
      Process.sleep(400)

      refute_receive {:file_changed, _}, 200
    end
  end

  defp wait_for_pipeline do
    wait_for_idle(Cerno.Process.Accumulator, :processing, MapSet.new(), &Kernel.==/2)
    wait_for_idle(Cerno.Process.Reconciler, :running, false, &Kernel.==/2)
    wait_for_idle(Cerno.Process.Organiser, :running, false, &Kernel.==/2)
  end

  defp wait_for_idle(server, key, expected, comparator, elapsed \\ 0) do
    state = :sys.get_state(server)
    value = Map.get(state, key)

    if comparator.(value, expected) do
      :ok
    else
      if elapsed >= 5_000 do
        :ok
      else
        Process.sleep(100)
        wait_for_idle(server, key, expected, comparator, elapsed + 100)
      end
    end
  end
end
