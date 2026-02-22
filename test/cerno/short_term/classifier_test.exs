defmodule Cerno.ShortTerm.ClassifierTest do
  use ExUnit.Case, async: true

  alias Cerno.ShortTerm.Classifier

  describe "classify/1 with string input" do
    test "classifies warning content" do
      result = Classifier.classify("Never use eval in production code, it is dangerous.")
      assert result.category == :warning
    end

    test "classifies convention content" do
      result = Classifier.classify("Always use snake_case for variable naming, keep style consistent.")
      assert result.category == :convention
    end

    test "classifies technique content" do
      result = Classifier.classify("How to implement a GenServer pattern step by step.")
      assert result.category == :technique
    end

    test "classifies fact content" do
      result = Classifier.classify("The API endpoint requires version 3 of the schema.")
      assert result.category == :fact
    end

    test "defaults to :fact when no signals match" do
      result = Classifier.classify("Something vague and unclassifiable.")
      assert result.category == :fact
    end
  end

  describe "classify/1 with fragment map" do
    test "uses section_heading for classification" do
      result = Classifier.classify(%{
        content: "Run mix test for all specs.",
        section_heading: "Testing"
      })

      assert "testing" in result.tags
    end

    test "detects domain from content" do
      result = Classifier.classify(%{
        content: "Use Ecto changesets for all database validation in Phoenix.",
        section_heading: nil
      })

      assert result.domain == "elixir"
    end
  end

  describe "tag detection" do
    test "detects testing tag" do
      result = Classifier.classify("Write ExUnit tests with assert and mock dependencies.")
      assert "testing" in result.tags
    end

    test "detects error-handling tag" do
      result = Classifier.classify("Rescue exceptions and raise custom errors.")
      assert "error-handling" in result.tags
    end

    test "detects multiple tags" do
      result = Classifier.classify("Test the database query performance with benchmarks.")
      assert "testing" in result.tags
      assert "database" in result.tags
      assert "performance" in result.tags
    end

    test "limits tags to 5" do
      assert length(Classifier.classify("test database api deploy refactor error performance security doc").tags) <= 5
    end
  end

  describe "domain detection" do
    test "detects elixir domain" do
      result = Classifier.classify("Use GenServer and Ecto with Phoenix LiveView.")
      assert result.domain == "elixir"
    end

    test "detects python domain" do
      result = Classifier.classify("Install Django with pip in a venv.")
      assert result.domain == "python"
    end

    test "returns nil when no domain matches" do
      result = Classifier.classify("Keep things simple and organized.")
      assert result.domain == nil
    end
  end

  describe "classification structure" do
    test "returns expected keys" do
      result = Classifier.classify("Some content here.")
      assert Map.has_key?(result, :category)
      assert Map.has_key?(result, :tags)
      assert Map.has_key?(result, :domain)
      assert is_atom(result.category)
      assert is_list(result.tags)
    end
  end
end
