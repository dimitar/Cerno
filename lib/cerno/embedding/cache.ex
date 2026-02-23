defmodule Cerno.Embedding.Cache do
  @moduledoc """
  ETS-backed cache for embeddings.

  Avoids redundant API calls for recently embedded text.
  Cache key is the SHA-256 hash of the text content.
  """

  use GenServer

  @table_name :embedding_cache
  @max_entries 10_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Look up a cached embedding by text content."
  @spec get(String.t()) :: {:ok, [float()]} | :miss
  def get(text) do
    key = hash_key(text)

    case :ets.lookup(@table_name, key) do
      [{^key, embedding, _inserted_at}] -> {:ok, embedding}
      [] -> :miss
    end
  end

  @doc "Store an embedding in the cache."
  @spec put(String.t(), [float()]) :: :ok
  def put(text, embedding) do
    key = hash_key(text)
    :ets.insert(@table_name, {key, embedding, System.monotonic_time()})
    maybe_evict()
    :ok
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    table = :ets.new(@table_name, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{table: table}}
  end

  defp hash_key(text) do
    :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
  end

  defp maybe_evict do
    if :ets.info(@table_name, :size) > @max_entries do
      # Evict oldest 10% using select to only fetch keys and timestamps
      evict_count = div(@max_entries, 10)

      keys_with_ts =
        :ets.select(@table_name, [{{:"$1", :_, :"$2"}, [], [{{:"$1", :"$2"}}]}])
        |> Enum.sort_by(fn {_key, ts} -> ts end)
        |> Enum.take(evict_count)

      Enum.each(keys_with_ts, fn {key, _ts} ->
        :ets.delete(@table_name, key)
      end)
    end
  end
end
