defmodule Cerno.Atomic.ParserTest do
  use ExUnit.Case, async: true

  alias Cerno.Atomic.Parser
  alias Cerno.Atomic.Parser.ClaudeMd
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

  # --- Dispatcher tests ---

  describe "Parser.parse/1 (dispatcher)" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "cerno_test_#{:rand.uniform(100_000)}")
      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      {:ok, tmp_dir: tmp_dir}
    end

    test "routes CLAUDE.md to ClaudeMd parser", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "CLAUDE.md")
      File.write!(path, @sample_claude_md)

      assert {:ok, fragments} = Parser.parse(path)
      assert length(fragments) >= 3
      assert Enum.all?(fragments, &is_struct(&1, Fragment))
    end

    test "returns :unknown_format for unrecognised files", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "random.txt")
      File.write!(path, "some content")

      assert {:error, :unknown_format} = Parser.parse(path)
    end
  end

  describe "Parser.find_parser/1" do
    test "finds ClaudeMd for CLAUDE.md" do
      assert {:ok, ClaudeMd} = Parser.find_parser("CLAUDE.md")
    end

    test "returns :error for unknown filename" do
      assert :error = Parser.find_parser("unknown.txt")
    end
  end

  describe "Parser.parsers/0" do
    test "includes ClaudeMd" do
      assert ClaudeMd in Parser.parsers()
    end
  end

  describe "Parser.parse_directory/1" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "cerno_dir_test_#{:rand.uniform(100_000)}")
      File.mkdir_p!(Path.join(tmp_dir, "project_a"))
      File.mkdir_p!(Path.join(tmp_dir, "project_b"))
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      {:ok, tmp_dir: tmp_dir}
    end

    test "finds and parses CLAUDE.md files across subdirectories", %{tmp_dir: tmp_dir} do
      File.write!(Path.join([tmp_dir, "project_a", "CLAUDE.md"]), "## Rules\n\nRule A")
      File.write!(Path.join([tmp_dir, "project_b", "CLAUDE.md"]), "## Rules\n\nRule B")

      assert {:ok, fragments} = Parser.parse_directory(tmp_dir)
      assert length(fragments) == 2
      projects = Enum.map(fragments, & &1.source_project) |> Enum.sort()
      assert projects == ["project_a", "project_b"]
    end

    test "ignores non-matching files", %{tmp_dir: tmp_dir} do
      File.write!(Path.join([tmp_dir, "project_a", "CLAUDE.md"]), "## Rules\n\nRule A")
      File.write!(Path.join([tmp_dir, "project_a", "notes.txt"]), "not a context file")

      assert {:ok, fragments} = Parser.parse_directory(tmp_dir)
      assert length(fragments) == 1
    end
  end

  describe "Parser.hash_file/1" do
    test "produces consistent hash" do
      assert Parser.hash_file("hello") == Parser.hash_file("hello")
    end

    test "different content produces different hash" do
      refute Parser.hash_file("hello") == Parser.hash_file("world")
    end
  end

  # --- ClaudeMd-specific tests ---

  describe "ClaudeMd.file_pattern/0" do
    test "returns CLAUDE.md" do
      assert ClaudeMd.file_pattern() == "CLAUDE.md"
    end
  end

  describe "ClaudeMd.split_sections/1" do
    test "splits by H2 headings" do
      sections = ClaudeMd.split_sections(@sample_claude_md)
      assert length(sections) == 4

      [preamble, conventions, architecture, testing] = sections
      assert preamble.heading == nil
      assert conventions.heading == "Conventions"
      assert architecture.heading == "Architecture"
      assert testing.heading == "Testing"
    end

    test "captures content within sections" do
      sections = ClaudeMd.split_sections(@sample_claude_md)
      conventions = Enum.find(sections, &(&1.heading == "Conventions"))
      assert String.contains?(conventions.content, "snake_case")
    end

    test "tracks line ranges" do
      sections = ClaudeMd.split_sections(@sample_claude_md)
      [preamble | _] = sections
      assert preamble.line_start == 1
      assert preamble.line_end > 1
    end

    test "handles file with no H2 headings" do
      sections = ClaudeMd.split_sections("Just some text\nwith no headings")
      assert length(sections) == 1
      assert hd(sections).heading == nil
    end

    test "handles empty content" do
      sections = ClaudeMd.split_sections("")
      assert length(sections) == 1
    end
  end

  describe "ClaudeMd.parse/1" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "cerno_test_#{:rand.uniform(100_000)}")
      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      {:ok, tmp_dir: tmp_dir}
    end

    test "parses a CLAUDE.md file into fragments", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "CLAUDE.md")
      File.write!(path, @sample_claude_md)

      assert {:ok, fragments} = ClaudeMd.parse(path)
      assert length(fragments) >= 3
      assert Enum.all?(fragments, &is_struct(&1, Fragment))
    end

    test "fragments have deterministic IDs", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "CLAUDE.md")
      File.write!(path, @sample_claude_md)

      {:ok, fragments1} = ClaudeMd.parse(path)
      {:ok, fragments2} = ClaudeMd.parse(path)

      ids1 = Enum.map(fragments1, & &1.id)
      ids2 = Enum.map(fragments2, & &1.id)
      assert ids1 == ids2
    end

    test "returns error for nonexistent file" do
      assert {:error, _} = ClaudeMd.parse("/nonexistent/CLAUDE.md")
    end

    test "sets source_project from directory name", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "CLAUDE.md")
      File.write!(path, @sample_claude_md)

      {:ok, fragments} = ClaudeMd.parse(path)
      project_name = Path.basename(tmp_dir)
      assert Enum.all?(fragments, &(&1.source_project == project_name))
    end
  end
end
