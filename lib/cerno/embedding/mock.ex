defmodule Cerno.Embedding.Mock do
  @moduledoc """
  Mock embedding provider for tests.

  Returns deterministic embeddings based on content hashing so that
  identical content always gets the same embedding and different content
  gets different (but consistent) embeddings.
  """

  @behaviour Cerno.Embedding

  @dimension 1536

  @impl true
  def embed(text) do
    {:ok, deterministic_embedding(text)}
  end

  @impl true
  def embed_batch(texts) do
    {:ok, Enum.map(texts, &deterministic_embedding/1)}
  end

  @impl true
  def dimension, do: @dimension

  @doc """
  Generate a deterministic embedding from text content.

  Uses SHA-256 hash bytes to seed a reproducible float vector.
  """
  def deterministic_embedding(text) do
    hash = :crypto.hash(:sha256, text)
    bytes = :binary.bin_to_list(hash)

    # Extend hash bytes to fill the dimension by cycling
    Stream.cycle(bytes)
    |> Enum.take(@dimension)
    |> Enum.map(fn byte -> (byte - 128) / 128.0 end)
  end
end
