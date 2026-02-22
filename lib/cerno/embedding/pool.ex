defmodule Cerno.Embedding.Pool do
  @moduledoc """
  GenServer that batches embedding requests for efficiency.

  Collects individual embedding requests and sends them as a batch
  to the configured provider. Reduces API calls and improves throughput.
  """

  use GenServer

  @batch_size 20
  @flush_interval_ms 500

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Request an embedding, returns {:ok, embedding} or {:error, reason}."
  @spec get_embedding(String.t(), timeout()) :: {:ok, [float()]} | {:error, term()}
  def get_embedding(text, timeout \\ 30_000) do
    GenServer.call(__MODULE__, {:embed, text}, timeout)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    schedule_flush()
    {:ok, %{queue: [], timer_ref: nil}}
  end

  @impl true
  def handle_call({:embed, text}, from, state) do
    queue = [{from, text} | state.queue]

    if length(queue) >= @batch_size do
      flush_queue(queue)
      {:noreply, %{state | queue: []}}
    else
      {:noreply, %{state | queue: queue}}
    end
  end

  @impl true
  def handle_info(:flush, state) do
    if state.queue != [] do
      flush_queue(state.queue)
    end

    schedule_flush()
    {:noreply, %{state | queue: []}}
  end

  defp flush_queue(queue) do
    queue = Enum.reverse(queue)
    texts = Enum.map(queue, fn {_from, text} -> text end)
    callers = Enum.map(queue, fn {from, _text} -> from end)

    case Cerno.Embedding.embed_batch(texts) do
      {:ok, embeddings} ->
        Enum.zip(callers, embeddings)
        |> Enum.each(fn {from, embedding} ->
          GenServer.reply(from, {:ok, embedding})
        end)

      {:error, reason} ->
        Enum.each(callers, fn from ->
          GenServer.reply(from, {:error, reason})
        end)
    end
  end

  defp schedule_flush do
    Process.send_after(self(), :flush, @flush_interval_ms)
  end
end
