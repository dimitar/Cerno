defmodule Cerno.AccumulationRunTest do
  use ExUnit.Case

  alias Cerno.AccumulationRun
  alias Cerno.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  describe "start/1" do
    test "creates a running accumulation run" do
      assert {:ok, run} = AccumulationRun.start("/some/project")
      assert run.project_path == "/some/project"
      assert run.status == "running"
      assert run.started_at != nil
      assert run.fragments_found == 0
      assert run.insights_created == 0
      assert run.insights_updated == 0
      assert run.errors == []
    end
  end

  describe "complete/2" do
    test "marks run as completed with stats" do
      {:ok, run} = AccumulationRun.start("/some/project")

      stats = %{fragments_found: 5, insights_created: 3, insights_updated: 2}
      assert {:ok, completed} = AccumulationRun.complete(run, stats)
      assert completed.status == "completed"
      assert completed.fragments_found == 5
      assert completed.insights_created == 3
      assert completed.insights_updated == 2
      assert completed.completed_at != nil
    end
  end

  describe "fail/2" do
    test "marks run as failed with error message" do
      {:ok, run} = AccumulationRun.start("/some/project")

      assert {:ok, failed} = AccumulationRun.fail(run, "Parse error: invalid format")
      assert failed.status == "failed"
      assert "Parse error: invalid format" in failed.errors
      assert failed.completed_at != nil
    end

    test "accumulates multiple errors" do
      {:ok, run} = AccumulationRun.start("/some/project")

      {:ok, run} = AccumulationRun.fail(run, "first error")
      # Simulate another fail by calling again
      assert {:ok, run} = AccumulationRun.fail(run, "second error")
      assert length(run.errors) == 2
    end
  end

  describe "changeset/2" do
    test "validates required project_path" do
      changeset = AccumulationRun.changeset(%AccumulationRun{}, %{})
      refute changeset.valid?
      assert {:project_path, _} = hd(changeset.errors)
    end

    test "validates status inclusion" do
      changeset = AccumulationRun.changeset(%AccumulationRun{}, %{
        project_path: "/foo",
        status: "invalid_status"
      })
      refute changeset.valid?
    end
  end
end
