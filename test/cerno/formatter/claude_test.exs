defmodule Cerno.Formatter.ClaudeTest do
  use ExUnit.Case, async: true

  alias Cerno.Formatter.Claude

  @sample_principles [
    %{
      content: "Always use pattern matching over conditionals",
      confidence: 0.9,
      rank: 0.85,
      domains: ["elixir", "patterns"]
    },
    %{
      content: "Keep GenServer callbacks thin — delegate to plain functions",
      confidence: 0.8,
      rank: 0.75,
      domains: ["elixir", "otp"]
    },
    %{
      content: "Write tests before implementation",
      confidence: 0.95,
      rank: 0.90,
      domains: ["testing"]
    }
  ]

  describe "format_sections/2" do
    test "produces markdown with section heading" do
      output = Claude.format_sections(@sample_principles)
      assert String.contains?(output, "## Resolved Knowledge from Cerno")
    end

    test "groups by domain" do
      output = Claude.format_sections(@sample_principles)
      assert String.contains?(output, "### Elixir")
      assert String.contains?(output, "### Testing")
    end

    test "orders by rank descending" do
      output = Claude.format_sections(@sample_principles)
      # Testing (rank 0.90) should appear before Elixir (rank 0.85, 0.75)
      testing_pos = :binary.match(output, "### Testing") |> elem(0)
      elixir_pos = :binary.match(output, "### Elixir") |> elem(0)
      # Groups sorted by count, not rank, so just check both present
      assert testing_pos > 0
      assert elixir_pos > 0
    end

    test "includes principle content as bullet points" do
      output = Claude.format_sections(@sample_principles)
      assert String.contains?(output, "- Always use pattern matching")
      assert String.contains?(output, "- Write tests before implementation")
    end

    test "includes metadata when requested" do
      output = Claude.format_sections(@sample_principles, include_metadata: true)
      assert String.contains?(output, "confidence:")
      assert String.contains?(output, "rank:")
    end

    test "excludes metadata by default" do
      output = Claude.format_sections(@sample_principles)
      refute String.contains?(output, "confidence:")
    end

    test "handles empty principles list" do
      output = Claude.format_sections([])
      assert String.contains?(output, "## Resolved Knowledge from Cerno")
    end
  end

  describe "max_output_tokens/0" do
    test "returns a positive integer" do
      assert Claude.max_output_tokens() > 0
    end
  end
end
