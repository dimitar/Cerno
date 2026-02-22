defmodule Cerno.ResolutionRunTest do
  use ExUnit.Case

  alias Cerno.ResolutionRun
  alias Cerno.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  describe "start/2" do
    test "creates a run with running status" do
      {:ok, run} = ResolutionRun.start("/path/to/CLAUDE.md")

      assert run.target_path == "/path/to/CLAUDE.md"
      assert run.agent_type == "claude"
      assert run.status == "running"
      assert run.principles_resolved == 0
      assert run.conflicts_detected == 0
      assert run.started_at != nil
      assert run.completed_at == nil
    end

    test "accepts custom agent type" do
      {:ok, run} = ResolutionRun.start("/path/to/.cursorrules", "cursor")
      assert run.agent_type == "cursor"
    end
  end

  describe "complete/2" do
    test "marks run as completed with stats" do
      {:ok, run} = ResolutionRun.start("/path/to/CLAUDE.md")

      {:ok, completed} =
        ResolutionRun.complete(run, %{
          principles_resolved: 5,
          conflicts_detected: 1
        })

      assert completed.status == "completed"
      assert completed.principles_resolved == 5
      assert completed.conflicts_detected == 1
      assert completed.completed_at != nil
    end
  end

  describe "fail/1" do
    test "marks run as failed" do
      {:ok, run} = ResolutionRun.start("/path/to/CLAUDE.md")
      {:ok, failed} = ResolutionRun.fail(run)

      assert failed.status == "failed"
      assert failed.completed_at != nil
    end
  end

  describe "changeset/2" do
    test "requires target_path" do
      changeset = ResolutionRun.changeset(%ResolutionRun{}, %{})
      refute changeset.valid?
      assert {:target_path, _} = hd(changeset.errors)
    end

    test "validates status" do
      changeset = ResolutionRun.changeset(%ResolutionRun{}, %{target_path: "/p", status: "invalid"})
      refute changeset.valid?
    end
  end
end
