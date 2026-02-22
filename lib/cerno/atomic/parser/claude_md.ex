defmodule Cerno.Atomic.Parser.ClaudeMd do
  @moduledoc """
  Parser for Claude's `CLAUDE.md` context files.

  Splits the file by H2 headings (`## ...`). Each section becomes a Fragment
  with a deterministic ID, source tracking, and line range information.
  """

  @behaviour Cerno.Atomic.Parser

  alias Cerno.Atomic.{Fragment, Parser}

  @impl true
  def file_pattern, do: "CLAUDE.md"

  @impl true
  def parse(path) do
    with {:ok, content} <- File.read(path) do
      file_hash = Parser.hash_file(content)
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
