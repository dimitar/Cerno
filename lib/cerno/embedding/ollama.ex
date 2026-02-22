defmodule Cerno.Embedding.Ollama do
  @moduledoc """
  Ollama embedding provider.

  Uses a local Ollama instance to generate embeddings.
  Default model: nomic-embed-text (768 dimensions).

  Configuration:
    config :cerno, :embedding,
      provider: Cerno.Embedding.Ollama,
      dimension: 768,
      ollama_url: "http://localhost:11434",
      ollama_model: "nomic-embed-text"
  """

  @behaviour Cerno.Embedding

  @default_model "nomic-embed-text"
  @default_dimension 768
  @default_url "http://localhost:11434"

  @impl true
  def embed(text) do
    case embed_batch([text]) do
      {:ok, [embedding]} -> {:ok, embedding}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def embed_batch(texts) when is_list(texts) do
    config = Application.get_env(:cerno, :embedding, [])
    base_url = Keyword.get(config, :ollama_url, @default_url)
    model = Keyword.get(config, :ollama_model, @default_model)
    url = "#{base_url}/api/embed"

    body = %{
      model: model,
      input: texts
    }

    case Req.post(url, json: body, receive_timeout: 60_000) do
      {:ok, %{status: 200, body: %{"embeddings" => embeddings}}} ->
        {:ok, embeddings}

      {:ok, %{status: status, body: body}} ->
        {:error, {:ollama_error, status, body}}

      {:error, %{reason: :econnrefused}} ->
        {:error, :ollama_not_running}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def dimension do
    config = Application.get_env(:cerno, :embedding, [])
    Keyword.get(config, :dimension, @default_dimension)
  end
end
