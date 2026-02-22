defmodule Cerno.Process.OrganiserTest do
  use ExUnit.Case

  alias Cerno.Process.Organiser
  alias Cerno.ShortTerm.Insight
  alias Cerno.LongTerm.Principle
  alias Cerno.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp insert_promotable_insight(content) do
    now = DateTime.utc_now()
    emb = Cerno.Embedding.Mock.deterministic_embedding(content)

    {:ok, insight} =
      %Insight{}
      |> Insight.changeset(%{
        content: content,
        content_hash: Insight.hash_content(content),
        embedding: emb,
        category: :convention,
        confidence: 0.8,
        observation_count: 5,
        first_seen_at: now,
        last_seen_at: now,
        status: :active
      })
      |> Repo.insert()

    insight
  end

  describe "organise/0" do
    test "runs full pipeline and promotes insights to principles" do
      insert_promotable_insight("Always use pattern matching in Elixir")
      insert_promotable_insight("Prefer immutable data structures")

      # Organise runs async, so we need to wait
      # Use a simple poll approach
      Organiser.organise()
      Process.sleep(500)

      import Ecto.Query
      principle_count = Repo.aggregate(from(p in Principle), :count)
      assert principle_count >= 1
    end

    test "runs without errors when nothing to promote" do
      Organiser.organise()
      Process.sleep(200)

      import Ecto.Query
      assert Repo.aggregate(from(p in Principle), :count) == 0
    end
  end
end
