defmodule Cerno.Embedding do
  @moduledoc """
  Behaviour for embedding providers.

  Cerno uses embeddings for semantic deduplication, similarity search,
  clustering, and contradiction detection. The provider is pluggable —
  API-based (OpenAI, Voyage) or local (Nx/Bumblebee).
  """

  @type embedding :: [float()]

  @doc "Generate an embedding for a single text."
  @callback embed(text :: String.t()) :: {:ok, embedding()} | {:error, term()}

  @doc "Generate embeddings for a batch of texts."
  @callback embed_batch(texts :: [String.t()]) :: {:ok, [embedding()]} | {:error, term()}

  @doc "Return the dimension of embeddings produced by this provider."
  @callback dimension() :: pos_integer()

  @doc "Get the configured embedding provider module."
  @spec provider() :: module()
  def provider do
    Application.get_env(:cerno, :embedding)[:provider] || Cerno.Embedding.OpenAI
  end

  @doc "Embed a single text using the configured provider."
  @spec embed(String.t()) :: {:ok, embedding()} | {:error, term()}
  def embed(text), do: provider().embed(text)

  @doc "Embed a batch of texts using the configured provider."
  @spec embed_batch([String.t()]) :: {:ok, [embedding()]} | {:error, term()}
  def embed_batch(texts), do: provider().embed_batch(texts)

  @doc "Get the embedding dimension from the configured provider."
  @spec dimension() :: pos_integer()
  def dimension, do: provider().dimension()
end
