defmodule Cerno.Atomic.Parser do
  @moduledoc """
  Behaviour for parsing agent context files into Fragment structs.

  Different AI agents use different context file formats:
  - Claude → `CLAUDE.md` (markdown, H2 sections)
  - Cursor → `.cursorrules` (flat rules)
  - Windsurf → `.windsurfrules`
  - ChatGPT → custom instructions

  Each format gets its own parser implementation. The behaviour defines
  the contract; the dispatcher routes files to the correct parser based
  on filename.
  """

  alias Cerno.Atomic.Fragment

  @doc "Parse a file at the given path into a list of Fragments."
  @callback parse(path :: String.t()) :: {:ok, [Fragment.t()]} | {:error, term()}

  @doc "The glob pattern this parser handles (e.g., `CLAUDE.md`, `.cursorrules`)."
  @callback file_pattern() :: String.t()

  @registered_parsers [
    Cerno.Atomic.Parser.ClaudeMd
  ]

  @doc """
  Parse a file using the appropriate parser for its filename.

  Returns `{:ok, [Fragment.t()]}` or `{:error, :unknown_format}` if no
  parser is registered for the file.
  """
  @spec parse(String.t()) :: {:ok, [Fragment.t()]} | {:error, term()}
  def parse(path) do
    filename = Path.basename(path)

    case find_parser(filename) do
      {:ok, parser} -> parser.parse(path)
      :error -> {:error, :unknown_format}
    end
  end

  @doc """
  Parse all recognised context files found under a directory (recursive).

  Scans for every registered file pattern and parses all matches.
  """
  @spec parse_directory(String.t()) :: {:ok, [Fragment.t()]}
  def parse_directory(dir) do
    fragments =
      parsers()
      |> Enum.flat_map(fn parser ->
        pattern =
          Path.join([dir, "**", parser.file_pattern()])
          |> normalize_path()

        Path.wildcard(pattern)
        |> Enum.flat_map(fn path ->
          case parser.parse(path) do
            {:ok, frags} -> frags
            {:error, _} -> []
          end
        end)
      end)

    {:ok, fragments}
  end

  @doc "List all registered parser modules."
  @spec parsers() :: [module()]
  def parsers, do: @registered_parsers

  @doc "Find the parser module for a given filename."
  @spec find_parser(String.t()) :: {:ok, module()} | :error
  def find_parser(filename) do
    Enum.find(parsers(), fn parser ->
      matches_pattern?(filename, parser.file_pattern())
    end)
    |> case do
      nil -> :error
      parser -> {:ok, parser}
    end
  end

  @doc "Compute SHA-256 hash of file content."
  @spec hash_file(String.t()) :: String.t()
  def hash_file(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  # Path.wildcard on Windows requires forward slashes
  defp normalize_path(path), do: String.replace(path, "\\", "/")

  defp matches_pattern?(filename, pattern) do
    if String.contains?(pattern, ["*", "?", "["]) do
      # Convert glob to regex: * → .*, ? → ., escape the rest
      regex_str =
        pattern
        |> Regex.escape()
        |> String.replace("\\*", ".*")
        |> String.replace("\\?", ".")

      Regex.match?(~r/^#{regex_str}$/, filename)
    else
      filename == pattern
    end
  end
end
