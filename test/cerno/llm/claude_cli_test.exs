defmodule Cerno.LLM.ClaudeCliTest do
  use ExUnit.Case, async: true

  alias Cerno.LLM.ClaudeCli

  defp make_fragment(content, opts \\ []) do
    %{
      content: content,
      section_heading: Keyword.get(opts, :section_heading),
      source_path: Keyword.get(opts, :source_path, "/project/CLAUDE.md")
    }
  end

  describe "build_file_prompt/1" do
    test "includes all fragment contents and section headings" do
      fragments = [
        make_fragment("Always use snake_case.", section_heading: "Conventions"),
        make_fragment("Build with msbuild.", section_heading: "Build Commands")
      ]

      prompt = ClaudeCli.build_file_prompt(fragments)

      assert prompt =~ "Always use snake_case."
      assert prompt =~ "Conventions"
      assert prompt =~ "Build with msbuild."
      assert prompt =~ "Build Commands"
      assert prompt =~ "cross-cutting"
    end

    test "uses preamble label when no section heading" do
      fragments = [make_fragment("Some content.")]
      prompt = ClaudeCli.build_file_prompt(fragments)

      assert prompt =~ "(preamble)"
    end
  end

  describe "parse_response/1 with learnings" do
    test "parses file-level learnings response (no actionable wrapper)" do
      json =
        Jason.encode!(%{
          "learnings" => [
            %{"content" => "Update both platforms when changing builds", "category" => "principle", "tags" => ["build"], "domain" => "cpp", "source_sections" => ["Build Commands"]},
            %{"content" => "Use staged loading for thread safety", "category" => "technique", "tags" => ["threading"], "domain" => "cpp", "source_sections" => ["Architecture", "Key Design Patterns"]}
          ]
        })

      assert {:ok, learnings} = ClaudeCli.parse_response(json)
      assert length(learnings) == 2
      assert Enum.at(learnings, 0).content == "Update both platforms when changing builds"
      assert Enum.at(learnings, 0).source_sections == ["Build Commands"]
      assert Enum.at(learnings, 1).source_sections == ["Architecture", "Key Design Patterns"]
    end

    test "parses multi-learning response with actionable wrapper" do
      json =
        Jason.encode!(%{
          "actionable" => true,
          "learnings" => [
            %{"content" => "Use snake_case for function names", "category" => "convention", "tags" => ["naming"], "domain" => "elixir"},
            %{"content" => "Prefer pattern matching over conditionals", "category" => "technique", "tags" => ["idiom"], "domain" => "elixir"}
          ]
        })

      assert {:ok, learnings} = ClaudeCli.parse_response(json)
      assert length(learnings) == 2
      assert Enum.at(learnings, 0).content == "Use snake_case for function names"
      assert Enum.at(learnings, 0).category == :convention
      assert Enum.at(learnings, 1).content == "Prefer pattern matching over conditionals"
      assert Enum.at(learnings, 1).category == :technique
    end

    test "parses single-learning response as list of one" do
      json =
        Jason.encode!(%{
          "actionable" => true,
          "learnings" => [
            %{"content" => "Always run tests before pushing", "category" => "convention", "tags" => ["testing"], "domain" => nil}
          ]
        })

      assert {:ok, learnings} = ClaudeCli.parse_response(json)
      assert length(learnings) == 1
      assert hd(learnings).content == "Always run tests before pushing"
      assert hd(learnings).category == :convention
    end

    test "parses wrapped learnings from --output-format json" do
      inner =
        Jason.encode!(%{
          "actionable" => true,
          "learnings" => [
            %{"content" => "Never use eval", "category" => "warning", "tags" => ["security"], "domain" => "javascript"}
          ]
        })

      json = Jason.encode!(%{"result" => inner})

      assert {:ok, [learning]} = ClaudeCli.parse_response(json)
      assert learning.category == :warning
      assert learning.tags == ["security"]
      assert learning.domain == "javascript"
      assert learning.content == "Never use eval"
    end

    test "backwards-compat: wraps old single-classification format in list" do
      json =
        Jason.encode!(%{
          "actionable" => true,
          "category" => "convention",
          "tags" => ["testing"],
          "domain" => "elixir",
          "summary" => "Use snake_case"
        })

      assert {:ok, [classification]} = ClaudeCli.parse_response(json)
      assert classification.category == :convention
      assert classification.tags == ["testing"]
      assert classification.domain == "elixir"
      assert classification.content == "Use snake_case"
    end

    test "normalizes unknown category to :fact" do
      json =
        Jason.encode!(%{
          "actionable" => true,
          "learnings" => [
            %{"content" => "Something", "category" => "unknown_category", "tags" => [], "domain" => nil}
          ]
        })

      assert {:ok, [learning]} = ClaudeCli.parse_response(json)
      assert learning.category == :fact
    end

    test "normalizes null domain to nil" do
      json =
        Jason.encode!(%{
          "actionable" => true,
          "learnings" => [
            %{"content" => "A fact", "category" => "fact", "tags" => [], "domain" => nil}
          ]
        })

      assert {:ok, [learning]} = ClaudeCli.parse_response(json)
      assert learning.domain == nil
    end

    test "normalizes empty string domain to nil" do
      json =
        Jason.encode!(%{
          "actionable" => true,
          "learnings" => [
            %{"content" => "A fact", "category" => "fact", "tags" => [], "domain" => ""}
          ]
        })

      assert {:ok, [learning]} = ClaudeCli.parse_response(json)
      assert learning.domain == nil
    end

    test "limits tags to 5" do
      json =
        Jason.encode!(%{
          "actionable" => true,
          "learnings" => [
            %{"content" => "Something", "category" => "fact", "tags" => ["a", "b", "c", "d", "e", "f", "g"], "domain" => nil}
          ]
        })

      assert {:ok, [learning]} = ClaudeCli.parse_response(json)
      assert length(learning.tags) == 5
    end

    test "filters out learnings with missing content" do
      json =
        Jason.encode!(%{
          "actionable" => true,
          "learnings" => [
            %{"content" => "Valid learning", "category" => "fact", "tags" => [], "domain" => nil},
            %{"category" => "fact", "tags" => [], "domain" => nil},
            %{"content" => "", "category" => "fact", "tags" => [], "domain" => nil}
          ]
        })

      assert {:ok, learnings} = ClaudeCli.parse_response(json)
      assert length(learnings) == 1
      assert hd(learnings).content == "Valid learning"
    end
  end

  describe "parse_response/1 with non-actionable result" do
    test "returns skip with reason" do
      json = Jason.encode!(%{"actionable" => false, "reason" => "This is a directory listing"})

      assert {:skip, "This is a directory listing"} = ClaudeCli.parse_response(json)
    end

    test "returns skip with default reason when no reason given" do
      json = Jason.encode!(%{"actionable" => false})

      assert {:skip, "not actionable"} = ClaudeCli.parse_response(json)
    end

    test "handles wrapped non-actionable response" do
      inner = Jason.encode!(%{"actionable" => false, "reason" => "structural heading"})
      json = Jason.encode!(%{"result" => inner})

      assert {:skip, "structural heading"} = ClaudeCli.parse_response(json)
    end
  end

  describe "parse_response/1 with invalid input" do
    test "returns error for non-JSON input" do
      assert {:error, _} = ClaudeCli.parse_response("not json at all")
    end

    test "returns error for unexpected format" do
      json = Jason.encode!(%{"something" => "else"})

      assert {:error, :unexpected_format} = ClaudeCli.parse_response(json)
    end

    test "extracts JSON from surrounding text" do
      inner = Jason.encode!(%{"actionable" => true, "category" => "convention", "tags" => [], "domain" => nil, "summary" => "A convention"})
      text = "Here is the result:\n#{inner}\nDone."

      assert {:ok, [learning]} = ClaudeCli.parse_response(text)
      assert learning.category == :convention
    end
  end

  describe "parse_response/1 with all valid categories" do
    test "accepts all valid category values" do
      for cat <- ~w(convention principle technique warning preference fact pattern) do
        json =
          Jason.encode!(%{
            "actionable" => true,
            "learnings" => [
              %{"content" => "Learning for #{cat}", "category" => cat, "tags" => [], "domain" => nil}
            ]
          })

        assert {:ok, [learning]} = ClaudeCli.parse_response(json)
        assert learning.category == String.to_atom(cat)
      end
    end
  end
end
