defmodule Cerno.Atomic.Fragment do
  @moduledoc """
  In-memory struct representing a raw text chunk extracted from a CLAUDE.md file.

  Fragments are the atomic layer — not persisted to the database, but used as
  input to the accumulation pipeline. Each fragment corresponds to a section
  (typically an H2 heading) of a CLAUDE.md file.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          content: String.t(),
          source_path: String.t(),
          source_project: String.t(),
          section_heading: String.t() | nil,
          line_range: {non_neg_integer(), non_neg_integer()},
          file_hash: String.t(),
          extracted_at: DateTime.t()
        }

  @enforce_keys [:id, :content, :source_path, :source_project, :file_hash, :extracted_at]
  defstruct [
    :id,
    :content,
    :source_path,
    :source_project,
    :section_heading,
    :line_range,
    :file_hash,
    :extracted_at
  ]

  @doc """
  Builds a deterministic ID from source path and content.
  This enables change detection — same path + same content = same fragment.
  """
  @spec build_id(String.t(), String.t()) :: String.t()
  def build_id(source_path, content) do
    :crypto.hash(:sha256, source_path <> content)
    |> Base.encode16(case: :lower)
  end
end
