defmodule Cerno.Atomic.ParserTest do
  use ExUnit.Case, async: true

  alias Cerno.Atomic.Parser
  alias Cerno.Atomic.Fragment

  @sample_claude_md """
  # Project Title

  Top-level description.

  ## Conventions

  - Use snake_case for variables
  - Keep functions small

  ## Architecture

  The system uses a layered design.

  ## Testing

  Run tests with `mix test`.
  """

  describe "split_sections/1" do
    test "splits by H2 headings" do
      sections = Parser.split_sections(@sample_claude_md)
      assert length(sections) == 4

      [preamble, conventions, architecture, testing] = sections
      assert preamble.heading == nil
      assert conventions.heading == "Conventions"
      assert architecture.heading == "Architecture"
      assert testing.heading == "Testing"
    end

    test "captures content within sections" do
      sections = Parser.split_sections(@sample_claude_md)
      conventions = Enum.find(sections, &(&1.heading == "Conventions"))
      assert String.contains?(conventions.content, "snake_case")
    end

    test "tracks line ranges" do
      sections = Parser.split_sections(@sample_claude_md)
      [preamble | _] = sections
      assert preamble.line_start == 1
      assert preamble.line_end > 1
    end

    test "handles file with no H2 headings" do
      sections = Parser.split_sections("Just some text\nwith no headings")
      assert length(sections) == 1
      assert hd(sections).heading == nil
    end

    test "handles empty content" do
      sections = Parser.split_sections("")
      assert length(sections) == 1
    end
  end

  describe "parse/1" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "cerno_test_#{:rand.uniform(100_000)}")
      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      {:ok, tmp_dir: tmp_dir}
    end

    test "parses a CLAUDE.md file into fragments", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "CLAUDE.md")
      File.write!(path, @sample_claude_md)

      assert {:ok, fragments} = Parser.parse(path)
      assert length(fragments) >= 3
      assert Enum.all?(fragments, &is_struct(&1, Fragment))
    end

    test "fragments have deterministic IDs", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "CLAUDE.md")
      File.write!(path, @sample_claude_md)

      {:ok, fragments1} = Parser.parse(path)
      {:ok, fragments2} = Parser.parse(path)

      ids1 = Enum.map(fragments1, & &1.id)
      ids2 = Enum.map(fragments2, & &1.id)
      assert ids1 == ids2
    end

    test "returns error for nonexistent file" do
      assert {:error, _} = Parser.parse("/nonexistent/CLAUDE.md")
    end

    test "sets source_project from directory name", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "CLAUDE.md")
      File.write!(path, @sample_claude_md)

      {:ok, fragments} = Parser.parse(path)
      project_name = Path.basename(tmp_dir)
      assert Enum.all?(fragments, &(&1.source_project == project_name))
    end
  end

  describe "hash_file/1" do
    test "produces consistent hash" do
      assert Parser.hash_file("hello") == Parser.hash_file("hello")
    end

    test "different content produces different hash" do
      refute Parser.hash_file("hello") == Parser.hash_file("world")
    end
  end
end
