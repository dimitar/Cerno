defmodule Cerno.Embedding.OpenAI do
  @moduledoc """
  OpenAI embedding provider.

  Uses the OpenAI embeddings API (text-embedding-3-small by default)
  to generate vector embeddings for text.
  """

  @behaviour Cerno.Embedding

  @default_model "text-embedding-3-small"
  @default_dimension 1536
  @api_url "https://api.openai.com/v1/embeddings"

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
    api_key = Keyword.get(config, :api_key)
    model = Keyword.get(config, :model, @default_model)

    if is_nil(api_key) do
      {:error, :missing_api_key}
    else
      body = %{
        input: texts,
        model: model,
        dimensions: dimension()
      }

      case Req.post(@api_url,
             json: body,
             headers: [{"authorization", "Bearer #{api_key}"}],
             receive_timeout: 30_000
           ) do
        {:ok, %{status: 200, body: %{"data" => data}}} ->
          embeddings =
            data
            |> Enum.sort_by(& &1["index"])
            |> Enum.map(& &1["embedding"])

          {:ok, embeddings}

        {:ok, %{status: status, body: body}} ->
          # Only include the error message, not the full response body
          {:error, {:api_error, status, Map.get(body, "error", %{})}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def dimension do
    config = Application.get_env(:cerno, :embedding, [])
    Keyword.get(config, :dimension, @default_dimension)
  end
end
