defmodule Cerno.Process.ResolverTest do
  use ExUnit.Case

  alias Cerno.Process.Resolver
  alias Cerno.LongTerm.Principle
  alias Cerno.ResolutionRun
  alias Cerno.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp insert_principle(attrs) do
    content = Map.get(attrs, :content, "principle #{System.unique_integer()}")

    defaults = %{
      content: content,
      content_hash: Cerno.ShortTerm.Insight.hash_content(content),
      embedding: Cerno.Embedding.Mock.deterministic_embedding(content),
      category: :learning,
      tags: [],
      domains: ["elixir"],
      confidence: 0.8,
      frequency: 5,
      recency_score: 1.0,
      source_quality: 0.6,
      rank: 0.7,
      status: :active
    }

    {:ok, principle} =
      %Principle{}
      |> Principle.changeset(Map.merge(defaults, attrs))
      |> Repo.insert()

    principle
  end

  describe "resolve/2 with dry_run" do
    test "returns formatted output without writing" do
      insert_principle(%{content: "Always use pattern matching in Elixir"})

      {:ok, output} = Resolver.resolve("/nonexistent/path/CLAUDE.md", dry_run: true, min_hybrid_score: 0.0)

      assert is_binary(output)
      assert String.contains?(output, "Resolved Knowledge from Cerno")
    end

    test "includes principles in output" do
      insert_principle(%{content: "Use GenServer for stateful processes", rank: 0.9, domains: ["elixir"]})

      {:ok, output} = Resolver.resolve("/nonexistent/path/CLAUDE.md", dry_run: true, min_hybrid_score: 0.0)

      assert String.contains?(output, "GenServer")
    end

    test "returns section header even with no principles" do
      {:ok, output} = Resolver.resolve("/nonexistent/path/CLAUDE.md", dry_run: true)

      assert String.contains?(output, "Resolved Knowledge from Cerno")
    end

    test "creates audit log entry" do
      insert_principle(%{content: "Test principle for audit", rank: 0.8})

      {:ok, _output} = Resolver.resolve("/nonexistent/path/CLAUDE.md", dry_run: true, min_hybrid_score: 0.0)

      import Ecto.Query
      runs = Repo.all(from(r in ResolutionRun, where: r.target_path == "/nonexistent/path/CLAUDE.md"))
      assert length(runs) >= 1

      run = hd(runs)
      assert run.status == "completed"
      assert run.agent_type == "claude"
    end
  end

  describe "resolve/2 with file write" do
    test "writes resolved content to file" do
      insert_principle(%{content: "Use supervision trees", rank: 0.8, domains: ["elixir"]})

      path = Path.join(System.tmp_dir!(), "test_resolve_#{System.unique_integer()}.md")

      File.write!(path, """
      # My Project

      ## Guidelines

      Some existing content.
      """)

      try do
        {:ok, _} = Resolver.resolve(path, min_hybrid_score: 0.0)

        content = File.read!(path)
        assert String.contains?(content, "My Project")
        assert String.contains?(content, "Resolved Knowledge from Cerno")
      after
        File.rm(path)
      end
    end

    test "preserves existing content when injecting" do
      path = Path.join(System.tmp_dir!(), "test_preserve_#{System.unique_integer()}.md")

      File.write!(path, """
      # Important Rules

      Never delete production data.
      """)

      try do
        {:ok, _} = Resolver.resolve(path)

        content = File.read!(path)
        assert String.contains?(content, "Important Rules")
        assert String.contains?(content, "Never delete production data")
      after
        File.rm(path)
      end
    end
  end
end
