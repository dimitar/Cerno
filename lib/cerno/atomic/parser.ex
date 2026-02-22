defmodule Cerno.Atomic.Parser do
  @moduledoc """
  Parses CLAUDE.md files into Fragment structs.

  Splits the file by H2 headings (`## ...`). Each section becomes a Fragment
  with a deterministic ID, source tracking, and line range information.
  Nested CLAUDE.md files are parsed independently with subdirectory context.
  """

  alias Cerno.Atomic.Fragment

  @doc """
  Parse a CLAUDE.md file at the given path into a list of Fragments.

  Returns `{:ok, [Fragment.t()]}` or `{:error, reason}`.
  """
  @spec parse(String.t()) :: {:ok, [Fragment.t()]} | {:error, term()}
  def parse(path) do
    with {:ok, content} <- File.read(path) do
      file_hash = hash_file(content)
      project = derive_project(path)
      now = DateTime.utc_now()

      fragments =
        content
        |> split_sections()
        |> Enum.map(fn section ->
          id = Fragment.build_id(path, section.content)

          %Fragment{
            id: id,
            content: section.content,
            source_path: Path.expand(path),
            source_project: project,
            section_heading: section.heading,
            line_range: {section.line_start, section.line_end},
            file_hash: file_hash,
            extracted_at: now
          }
        end)
        |> Enum.reject(fn f -> String.trim(f.content) == "" end)

      {:ok, fragments}
    end
  end

  @doc """
  Parse all CLAUDE.md files found under a directory (recursive).
  """
  @spec parse_directory(String.t()) :: {:ok, [Fragment.t()]} | {:error, term()}
  def parse_directory(dir) do
    pattern = Path.join([dir, "**", "CLAUDE.md"])

    fragments =
      Path.wildcard(pattern)
      |> Enum.flat_map(fn path ->
        case parse(path) do
          {:ok, frags} -> frags
          {:error, _} -> []
        end
      end)

    {:ok, fragments}
  end

  @doc "Compute SHA-256 hash of file content."
  @spec hash_file(String.t()) :: String.t()
  def hash_file(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  @doc """
  Split markdown content by H2 headings into sections.

  Content before the first H2 heading is captured as a section with
  heading `nil`. Each section includes its heading, content, and
  line range.
  """
  @spec split_sections(String.t()) :: [map()]
  def split_sections(content) do
    lines = String.split(content, "\n")

    {sections, current} =
      lines
      |> Enum.with_index(1)
      |> Enum.reduce({[], nil}, fn {line, line_num}, {sections, current} ->
        if h2_heading?(line) do
          heading = extract_heading(line)
          sections = if current, do: [finalize_section(current) | sections], else: sections
          new_section = %{heading: heading, lines: [], line_start: line_num, line_end: line_num}
          {sections, new_section}
        else
          if current do
            current = %{current | lines: [line | current.lines], line_end: line_num}
            {sections, current}
          else
            # Content before first heading
            new_section = %{heading: nil, lines: [line], line_start: line_num, line_end: line_num}
            {sections, new_section}
          end
        end
      end)

    sections = if current, do: [finalize_section(current) | sections], else: sections
    Enum.reverse(sections)
  end

  defp h2_heading?(line), do: String.match?(line, ~r/^##\s+/)

  defp extract_heading(line) do
    line
    |> String.replace(~r/^##\s+/, "")
    |> String.trim()
  end

  defp finalize_section(section) do
    content =
      section.lines
      |> Enum.reverse()
      |> Enum.join("\n")
      |> String.trim()

    %{
      heading: section.heading,
      content: content,
      line_start: section.line_start,
      line_end: section.line_end
    }
  end

  defp derive_project(path) do
    path
    |> Path.expand()
    |> Path.dirname()
    |> Path.basename()
  end
end
