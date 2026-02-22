defmodule Cerno.ShortTerm.Classifier do
  @moduledoc """
  Heuristic classifier for insight category, tags, and domain.

  Uses keyword matching to classify fragment content without requiring
  an LLM call. This provides a fast, deterministic baseline classification.
  A future LLM-based classifier can refine these results.
  """

  @type classification :: %{
          category: atom(),
          tags: [String.t()],
          domain: String.t() | nil
        }

  @doc """
  Classify a fragment's content into category, tags, and domain.

  Accepts either a plain string or a Fragment struct.
  """
  @spec classify(String.t() | map()) :: classification()
  def classify(%{content: content, section_heading: heading}) do
    classify_text(content, heading)
  end

  def classify(content) when is_binary(content) do
    classify_text(content, nil)
  end

  defp classify_text(content, heading) do
    lower = String.downcase(content)
    heading_lower = if heading, do: String.downcase(heading), else: ""

    %{
      category: detect_category(lower, heading_lower),
      tags: detect_tags(lower, heading_lower),
      domain: detect_domain(lower, heading_lower)
    }
  end

  # --- Category detection ---

  @category_signals %{
    warning: [
      "never", "don't", "do not", "avoid", "careful", "dangerous",
      "warning", "caution", "must not", "forbidden", "pitfall"
    ],
    convention: [
      "always", "convention", "naming", "style", "format", "prefer",
      "use snake_case", "use camelcase", "indentation", "consistent"
    ],
    principle: [
      "principle", "philosophy", "approach", "strategy", "guideline",
      "best practice", "rule of thumb"
    ],
    technique: [
      "how to", "technique", "pattern", "recipe", "step by step",
      "implementation", "method", "workflow"
    ],
    preference: [
      "prefer", "preference", "rather", "instead of", "favour", "favor",
      "recommended", "suggestion"
    ],
    fact: [
      "version", "requires", "dependency", "api", "endpoint",
      "schema", "table", "database", "port", "url", "path"
    ],
    pattern: [
      "pattern", "architecture", "structure", "layout", "design",
      "module", "layer", "separation"
    ]
  }

  defp detect_category(lower, heading_lower) do
    combined = lower <> " " <> heading_lower

    # Score each category by number of signal matches
    scores =
      @category_signals
      |> Enum.map(fn {category, signals} ->
        score = Enum.count(signals, &String.contains?(combined, &1))
        {category, score}
      end)
      |> Enum.reject(fn {_cat, score} -> score == 0 end)
      |> Enum.sort_by(fn {_cat, score} -> score end, :desc)

    case scores do
      [{category, _} | _] -> category
      [] -> :fact
    end
  end

  # --- Tag detection ---

  @tag_keywords %{
    "testing" => ["test", "spec", "assert", "mock", "fixture", "exunit"],
    "error-handling" => ["error", "exception", "rescue", "catch", "raise", "try"],
    "performance" => ["performance", "optimize", "cache", "fast", "slow", "benchmark"],
    "security" => ["security", "auth", "token", "password", "encrypt", "secret"],
    "database" => ["database", "query", "migration", "schema", "ecto", "repo", "sql"],
    "api" => ["api", "endpoint", "rest", "graphql", "request", "response"],
    "concurrency" => ["genserver", "process", "spawn", "task", "supervisor", "otp"],
    "documentation" => ["doc", "readme", "comment", "moduledoc"],
    "deployment" => ["deploy", "release", "docker", "ci", "cd", "pipeline"],
    "refactoring" => ["refactor", "clean", "simplify", "extract", "rename"]
  }

  defp detect_tags(lower, heading_lower) do
    combined = lower <> " " <> heading_lower

    tags =
      @tag_keywords
      |> Enum.filter(fn {_tag, keywords} ->
        Enum.any?(keywords, &String.contains?(combined, &1))
      end)
      |> Enum.map(fn {tag, _} -> tag end)

    # Add heading as a tag if present
    heading_tag =
      if heading_lower != "" do
        [heading_lower |> String.replace(~r/[^a-z0-9\s-]/, "") |> String.trim()]
      else
        []
      end

    (tags ++ heading_tag)
    |> Enum.uniq()
    |> Enum.take(5)
  end

  # --- Domain detection ---

  @domain_keywords %{
    "elixir" => ["elixir", "mix", "genserver", "ecto", "phoenix", "otp", "beam", "erlang", "iex"],
    "javascript" => ["javascript", "node", "npm", "react", "typescript", "jsx", "tsx"],
    "python" => ["python", "pip", "django", "flask", "pytest", "venv"],
    "ruby" => ["ruby", "rails", "gem", "bundler", "rspec"],
    "rust" => ["rust", "cargo", "crate", "borrow", "lifetime"],
    "go" => [" go ", "golang", "goroutine", "go mod"],
    "testing" => ["test", "spec", "tdd", "bdd", "coverage"],
    "architecture" => ["architecture", "design", "layer", "module", "microservice"],
    "devops" => ["docker", "kubernetes", "ci/cd", "deploy", "terraform"],
    "database" => ["postgres", "mysql", "sqlite", "redis", "database", "sql", "migration"]
  }

  defp detect_domain(lower, heading_lower) do
    combined = lower <> " " <> heading_lower

    scores =
      @domain_keywords
      |> Enum.map(fn {domain, keywords} ->
        score = Enum.count(keywords, &String.contains?(combined, &1))
        {domain, score}
      end)
      |> Enum.reject(fn {_domain, score} -> score == 0 end)
      |> Enum.sort_by(fn {_domain, score} -> score end, :desc)

    case scores do
      [{domain, _} | _] -> domain
      [] -> nil
    end
  end
end
