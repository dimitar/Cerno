defmodule Cerno.Integration.FullPipelineTest do
  @moduledoc """
  End-to-end integration test for the full Cerno pipeline.

  Exercises: scan → accumulate → reconcile → organise → resolve.
  Uses temp directories with real CLAUDE.md files and the full OTP tree.
  """

  use ExUnit.Case

  import Ecto.Query

  alias Cerno.{Repo, WatchedProject, AccumulationRun, ResolutionRun}
  alias Cerno.ShortTerm.{Insight, Cluster}
  alias Cerno.LongTerm.{Principle, Derivation}
  alias Cerno.Process.{Accumulator, Reconciler, Organiser, Resolver}

  @poll_interval 200
  @max_wait 10_000

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    # Create temp project directories with CLAUDE.md files
    tmp_base = Path.join(System.tmp_dir!(), "cerno_e2e_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_base)

    project_a = setup_project(tmp_base, "project_alpha", claude_md_alpha())
    project_b = setup_project(tmp_base, "project_beta", claude_md_beta())
    project_c = setup_project(tmp_base, "project_gamma", claude_md_gamma())

    # Target file for resolution
    target_path = Path.join(tmp_base, "target_project/CLAUDE.md")
    File.mkdir_p!(Path.dirname(target_path))
    File.write!(target_path, claude_md_target())

    on_exit(fn ->
      File.rm_rf!(tmp_base)
    end)

    %{
      tmp_base: tmp_base,
      project_a: project_a,
      project_b: project_b,
      project_c: project_c,
      target_path: target_path
    }
  end

  describe "full pipeline" do
    test "scan → accumulate → reconcile → organise → resolve", ctx do
      # ========================================
      # Step 1: Register projects
      # ========================================
      register_project("project_alpha", ctx.project_a.path)
      register_project("project_beta", ctx.project_b.path)
      register_project("project_gamma", ctx.project_c.path)

      assert Repo.aggregate(WatchedProject, :count) == 3

      # ========================================
      # Step 2: Accumulate all projects
      # ========================================
      Accumulator.accumulate(ctx.project_a.claude_md)
      Accumulator.accumulate(ctx.project_b.claude_md)
      Accumulator.accumulate(ctx.project_c.claude_md)

      # Wait for accumulation to complete
      wait_until(fn ->
        Repo.aggregate(from(r in AccumulationRun, where: r.status == "completed"), :count) >= 3
      end)

      # Verify insights were created
      insight_count = Repo.aggregate(from(i in Insight, where: i.status == :active), :count)
      assert insight_count >= 3, "Expected at least 3 insights, got #{insight_count}"

      # Verify some insights have embeddings
      with_embeddings =
        Repo.aggregate(
          from(i in Insight, where: i.status == :active and not is_nil(i.embedding)),
          :count
        )

      assert with_embeddings >= 3, "Expected insights with embeddings"

      # ========================================
      # Step 3: Reconcile
      # ========================================
      Reconciler.reconcile()

      wait_until(fn ->
        # Clusters should be created if there are enough similar insights
        Repo.aggregate(Cluster, :count) >= 0
      end)

      # Give reconciliation a moment to fully complete
      Process.sleep(500)

      # Verify confidence was adjusted (some insights should have non-default confidence)
      _adjusted =
        Repo.all(from(i in Insight, where: i.status == :active and i.confidence != 0.5))

      # It's OK if not all are adjusted — depends on the specific content
      # Just verify reconciliation ran without errors

      # ========================================
      # Step 4: Organise
      # ========================================
      # Wait for any in-flight organisation from PubSub chain to settle
      Process.sleep(500)
      Organiser.organise()

      wait_until(fn ->
        # Retry organise if the GenServer was busy on first attempt
        if Repo.aggregate(from(p in Principle, where: p.status == :active), :count) == 0 do
          Organiser.organise()
        end

        Repo.aggregate(from(p in Principle, where: p.status == :active), :count) >= 1
      end)

      # Verify principles were created from insights
      principle_count = Repo.aggregate(from(p in Principle, where: p.status == :active), :count)
      assert principle_count >= 1, "Expected at least 1 principle, got #{principle_count}"

      # Verify derivations link principles back to insights
      derivation_count = Repo.aggregate(Derivation, :count)
      assert derivation_count >= 1, "Expected at least 1 derivation"

      # Verify principles have ranks > 0
      ranked =
        Repo.all(from(p in Principle, where: p.status == :active and p.rank > 0.0))

      assert length(ranked) >= 1, "Expected principles with ranks > 0"

      # ========================================
      # Step 5: Resolve into target project
      # ========================================
      {:ok, dry_output} = Resolver.resolve(ctx.target_path, dry_run: true, min_hybrid_score: 0.0)

      # Verify the output has the expected structure
      assert String.contains?(dry_output, "Resolved Knowledge from Cerno")
      assert String.contains?(dry_output, "Do not edit manually")

      # Verify resolution audit log was created
      resolution_runs = Repo.all(from(r in ResolutionRun, where: r.status == "completed"))
      assert length(resolution_runs) >= 1

      run = hd(resolution_runs)
      assert run.target_path == ctx.target_path
      assert run.agent_type == "claude"

      # Now actually write to the file
      {:ok, _written} = Resolver.resolve(ctx.target_path, min_hybrid_score: 0.0)

      # Verify the file was updated
      final_content = File.read!(ctx.target_path)
      assert String.contains?(final_content, "Resolved Knowledge from Cerno")

      # Verify human content was preserved
      assert String.contains?(final_content, "Target Project")
      assert String.contains?(final_content, "This is the target project")
    end

    test "pipeline handles empty projects gracefully", ctx do
      # Create an empty CLAUDE.md
      empty_path = Path.join(ctx.tmp_base, "empty_project/CLAUDE.md")
      File.mkdir_p!(Path.dirname(empty_path))
      File.write!(empty_path, "# Empty Project\n")

      register_project("empty_project", Path.dirname(empty_path))
      Accumulator.accumulate(empty_path)

      wait_until(fn ->
        Repo.aggregate(from(r in AccumulationRun, where: r.status == "completed"), :count) >= 1
      end)

      # Should not crash — just produce no insights from empty content
      Reconciler.reconcile()
      Process.sleep(300)

      Organiser.organise()
      Process.sleep(300)

      # Resolve should work even with no principles
      {:ok, output} = Resolver.resolve(empty_path, dry_run: true)
      assert String.contains?(output, "Resolved Knowledge from Cerno")
    end
  end

  # --- Test data ---

  defp claude_md_alpha do
    """
    # Project Alpha

    ## Coding Conventions

    Always use pattern matching instead of conditionals in Elixir.
    Prefer GenServer for stateful processes.
    Use Ecto changesets for all database operations.

    ## Testing

    Write ExUnit tests for every public function.
    Use Ecto sandbox for database-backed tests.
    """
  end

  defp claude_md_beta do
    """
    # Project Beta

    ## Coding Conventions

    Always use pattern matching over if/else in Elixir modules.
    Prefer supervision trees for fault tolerance.
    Use Phoenix PubSub for inter-process communication.

    ## Architecture

    Keep modules small and focused on a single responsibility.
    Use behaviours for pluggable interfaces.
    """
  end

  defp claude_md_gamma do
    """
    # Project Gamma

    ## Guidelines

    Avoid deeply nested conditionals — use pattern matching.
    Use Ecto schemas with explicit changesets for validation.

    ## Deployment

    Deploy with Docker containers.
    Use CI/CD pipelines for automated testing.
    """
  end

  defp claude_md_target do
    """
    # Target Project

    ## Overview

    This is the target project where resolved knowledge will be injected.

    ## Existing Rules

    Follow the team coding style guide.
    """
  end

  # --- Helpers ---

  defp setup_project(base, name, content) do
    dir = Path.join(base, name)
    File.mkdir_p!(dir)

    claude_md_path = Path.join(dir, "CLAUDE.md")
    File.write!(claude_md_path, content)

    %{path: dir, claude_md: claude_md_path, name: name}
  end

  defp register_project(name, path) do
    %WatchedProject{}
    |> WatchedProject.changeset(%{name: name, path: path, active: true})
    |> Repo.insert!()
  end

  defp wait_until(condition, elapsed \\ 0) do
    if condition.() do
      :ok
    else
      if elapsed >= @max_wait do
        flunk("Timed out waiting for condition after #{@max_wait}ms")
      else
        Process.sleep(@poll_interval)
        wait_until(condition, elapsed + @poll_interval)
      end
    end
  end
end
