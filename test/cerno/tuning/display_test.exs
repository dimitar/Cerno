defmodule Cerno.Tuning.DisplayTest do
  use ExUnit.Case, async: true

  alias Cerno.Tuning.Display
  alias Cerno.ShortTerm.Insight
  alias Cerno.LongTerm.Principle
  alias Cerno.Atomic.Fragment

  # --- truncate/2 ---

  describe "truncate/2" do
    test "truncates long strings with ellipsis" do
      assert Display.truncate("hello world", 5) == "he..."
    end

    test "returns string as-is when at or under limit" do
      assert Display.truncate("hello", 5) == "hello"
      assert Display.truncate("hi", 5) == "hi"
    end

    test "handles nil" do
      assert Display.truncate(nil, 10) == ""
    end

    test "handles empty string" do
      assert Display.truncate("", 10) == ""
    end
  end

  # --- header/1 ---

  describe "header/1" do
    test "contains text and ANSI bright" do
      result = Display.header("Test Header")
      assert String.contains?(result, "Test Header")
      assert String.contains?(result, IO.ANSI.bright())
    end
  end

  # --- section/2 ---

  describe "section/2" do
    test "contains title and body" do
      result = Display.section("Title", "body content")
      assert String.contains?(result, "Title")
      assert String.contains?(result, "body content")
    end
  end

  # --- color_for_confidence/1 ---

  describe "color_for_confidence/1" do
    test "high confidence returns green" do
      assert Display.color_for_confidence(0.8) == IO.ANSI.green()
      assert Display.color_for_confidence(0.7) == IO.ANSI.green()
    end

    test "medium confidence returns yellow" do
      assert Display.color_for_confidence(0.5) == IO.ANSI.yellow()
      assert Display.color_for_confidence(0.4) == IO.ANSI.yellow()
    end

    test "low confidence returns red" do
      assert Display.color_for_confidence(0.2) == IO.ANSI.red()
      assert Display.color_for_confidence(0.39) == IO.ANSI.red()
    end
  end

  # --- color_for_status/1 ---

  describe "color_for_status/1" do
    test "active returns green" do
      assert Display.color_for_status(:active) == IO.ANSI.green()
    end

    test "contradicted returns red" do
      assert Display.color_for_status(:contradicted) == IO.ANSI.red()
    end

    test "superseded returns faint" do
      assert Display.color_for_status(:superseded) == IO.ANSI.faint()
    end

    test "pending_review returns yellow" do
      assert Display.color_for_status(:pending_review) == IO.ANSI.yellow()
    end

    test "decaying returns yellow" do
      assert Display.color_for_status(:decaying) == IO.ANSI.yellow()
    end

    test "pruned returns faint" do
      assert Display.color_for_status(:pruned) == IO.ANSI.faint()
    end

    test "unknown returns reset" do
      assert Display.color_for_status(:unknown) == IO.ANSI.reset()
    end
  end

  # --- table/2 ---

  describe "table/2" do
    test "renders header row and separator" do
      rows = [%{name: "Alice", age: 30}]
      result = Display.table(rows, [:name, :age])
      lines = String.split(result, "\n")

      assert Enum.any?(lines, &String.contains?(&1, "Name"))
      assert Enum.any?(lines, &String.contains?(&1, "Age"))
      assert Enum.any?(lines, &String.contains?(&1, "─"))
    end

    test "aligns columns" do
      rows = [
        %{name: "Alice", age: 30},
        %{name: "Bob", age: 7}
      ]

      result = Display.table(rows, [:name, :age])
      lines = String.split(result, "\n") |> Enum.reject(&(&1 == ""))

      # All data lines (skipping header and separator) should have similar structure
      assert length(lines) >= 4
    end

    test "handles empty rows" do
      result = Display.table([], [:name, :age])
      assert String.contains?(result, "No data")
    end

    test "formats atom values as strings" do
      rows = [%{status: :active}]
      result = Display.table(rows, [:status])
      assert String.contains?(result, "active")
    end

    test "formats float values rounded" do
      rows = [%{score: 0.12345}]
      result = Display.table(rows, [:score])
      assert String.contains?(result, "0.12")
    end

    test "formats nil as dash" do
      rows = [%{value: nil}]
      result = Display.table(rows, [:value])
      assert String.contains?(result, "—")
    end

    test "formats lists as joined" do
      rows = [%{tags: ["a", "b", "c"]}]
      result = Display.table(rows, [:tags])
      assert String.contains?(result, "a, b, c")
    end
  end

  # --- format_insight_list/1 ---

  describe "format_insight_list/1" do
    test "renders insights as table" do
      insights = [
        %Insight{
          id: 1,
          category: :convention,
          status: :active,
          confidence: 0.85,
          domain: "elixir",
          content: "Use pattern matching"
        }
      ]

      result = Display.format_insight_list(insights)
      assert String.contains?(result, "1")
      assert String.contains?(result, "convention")
      assert String.contains?(result, "active")
      assert String.contains?(result, "elixir")
      assert String.contains?(result, "Use pattern matching")
    end

    test "truncates long content" do
      insights = [
        %Insight{
          id: 1,
          category: :convention,
          status: :active,
          confidence: 0.5,
          domain: "elixir",
          content: String.duplicate("a", 100)
        }
      ]

      result = Display.format_insight_list(insights)
      assert String.contains?(result, "...")
    end
  end

  # --- format_insight_detail/1 ---

  describe "format_insight_detail/1" do
    test "renders all fields" do
      insight = %Insight{
        id: 1,
        content: "Test content",
        category: :convention,
        status: :active,
        confidence: 0.85,
        domain: "elixir",
        tags: ["testing"],
        observation_count: 5,
        first_seen_at: ~U[2025-01-01 00:00:00Z],
        last_seen_at: ~U[2025-06-01 00:00:00Z]
      }

      insight = Map.put(insight, :sources, [])
      insight = Map.put(insight, :clusters, [])
      insight = Map.put(insight, :contradictions_as_first, [])
      insight = Map.put(insight, :contradictions_as_second, [])
      insight = Map.put(insight, :derived_principles, [])

      result = Display.format_insight_detail(insight)
      assert String.contains?(result, "Test content")
      assert String.contains?(result, "convention")
      assert String.contains?(result, "active")
      assert String.contains?(result, "0.85")
      assert String.contains?(result, "elixir")
      assert String.contains?(result, "testing")
      assert String.contains?(result, "Sources")
    end

    test "renders derived principles section" do
      insight = %Insight{
        id: 1,
        content: "Test",
        category: :convention,
        status: :active,
        confidence: 0.5,
        domain: nil,
        tags: [],
        observation_count: 1,
        first_seen_at: ~U[2025-01-01 00:00:00Z],
        last_seen_at: ~U[2025-01-01 00:00:00Z]
      }

      principle = %Principle{id: 10, content: "Derived principle", rank: 0.8}

      insight =
        insight
        |> Map.put(:sources, [])
        |> Map.put(:clusters, [])
        |> Map.put(:contradictions_as_first, [])
        |> Map.put(:contradictions_as_second, [])
        |> Map.put(:derived_principles, [principle])

      result = Display.format_insight_detail(insight)
      assert String.contains?(result, "Derived Principles")
      assert String.contains?(result, "Derived principle")
    end
  end

  # --- format_principle_list/1 ---

  describe "format_principle_list/1" do
    test "renders principles as table" do
      principles = [
        %Principle{
          id: 1,
          category: :heuristic,
          status: :active,
          rank: 0.75,
          domains: ["elixir", "otp"],
          content: "Prefer pattern matching over conditionals"
        }
      ]

      result = Display.format_principle_list(principles)
      assert String.contains?(result, "1")
      assert String.contains?(result, "heuristic")
      assert String.contains?(result, "active")
      assert String.contains?(result, "0.75")
      assert String.contains?(result, "elixir, otp")
    end
  end

  # --- format_principle_detail/1 ---

  describe "format_principle_detail/1" do
    test "renders all fields and sections" do
      principle = %Principle{
        id: 1,
        content: "Test principle",
        elaboration: "More details",
        category: :heuristic,
        status: :active,
        rank: 0.75,
        confidence: 0.85,
        frequency: 10,
        recency_score: 0.9,
        source_quality: 0.7,
        domains: ["elixir"],
        tags: ["testing"]
      }

      principle =
        principle
        |> Map.put(:derivations, [])
        |> Map.put(:links_as_source, [])
        |> Map.put(:links_as_target, [])
        |> Map.put(:rank_breakdown, %{
          confidence: 0.30,
          frequency: 0.20,
          recency: 0.18,
          quality: 0.11,
          links: 0.01
        })

      result = Display.format_principle_detail(principle)
      assert String.contains?(result, "Test principle")
      assert String.contains?(result, "More details")
      assert String.contains?(result, "Rank Breakdown")
      assert String.contains?(result, "confidence")
    end
  end

  # --- format_fragment_list/1 ---

  describe "format_fragment_list/1" do
    test "renders fragments as table with line ranges" do
      fragments = [
        %Fragment{
          id: "abc",
          content: "Fragment content here",
          source_path: "/tmp/CLAUDE.md",
          source_project: "test",
          section_heading: "Overview",
          line_range: {1, 10},
          file_hash: "hash",
          extracted_at: DateTime.utc_now()
        }
      ]

      result = Display.format_fragment_list(fragments)
      assert String.contains?(result, "Overview")
      assert String.contains?(result, "L1–10")
      assert String.contains?(result, "Fragment content here")
    end

    test "handles nil section heading" do
      fragments = [
        %Fragment{
          id: "abc",
          content: "Content",
          source_path: "/tmp/CLAUDE.md",
          source_project: "test",
          section_heading: nil,
          line_range: {1, 5},
          file_hash: "hash",
          extracted_at: DateTime.utc_now()
        }
      ]

      result = Display.format_fragment_list(fragments)
      assert String.contains?(result, "—")
    end
  end

  # --- format_stats/1 ---

  describe "format_stats/1" do
    test "renders stats sections" do
      stats = %{
        insights: %{total: 10, by_status: %{active: 8, contradicted: 2}, by_category: %{convention: 5, principle: 5}, top_domains: %{"elixir" => 7}},
        principles: %{total: 3, by_status: %{active: 3}, by_category: %{heuristic: 2, learning: 1}},
        contradictions: %{total: 2, by_status: %{unresolved: 1, resolved: 1}},
        clusters: %{total: 1}
      }

      result = Display.format_stats(stats)
      assert String.contains?(result, "Insights")
      assert String.contains?(result, "10")
      assert String.contains?(result, "Principles")
      assert String.contains?(result, "Contradictions")
      assert String.contains?(result, "Clusters")
    end

    test "handles zero counts" do
      stats = %{
        insights: %{total: 0, by_status: %{}, by_category: %{}, top_domains: %{}},
        principles: %{total: 0, by_status: %{}, by_category: %{}},
        contradictions: %{total: 0, by_status: %{}},
        clusters: %{total: 0}
      }

      result = Display.format_stats(stats)
      assert String.contains?(result, "0")
    end
  end
end
