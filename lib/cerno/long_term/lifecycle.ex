defmodule Cerno.LongTerm.Lifecycle do
  @moduledoc """
  Manages the lifecycle of Principles: decay, rank recomputation, and pruning.

  - `apply_decay/0` — exponential recency decay with frequency-adjusted half-life
  - `recompute_ranks/0` — recalculates rank for all active/decaying principles
  - `apply_pruning/0` — transitions: active → decaying → pruned based on rank + staleness
  - `run/0` — runs all three in sequence
  """

  import Ecto.Query
  require Logger

  alias Cerno.Repo
  alias Cerno.LongTerm.{Principle, PrincipleLink}

  @doc """
  Run the full lifecycle pipeline: decay → recompute ranks → prune.
  """
  @spec run() :: :ok
  def run do
    {:ok, decayed} = apply_decay()
    {:ok, ranked} = recompute_ranks()
    {:ok, pruned} = apply_pruning()
    Logger.info("Lifecycle: #{decayed} decayed, #{ranked} ranked, #{pruned.decaying + pruned.pruned} status changes")
    :ok
  end

  @doc """
  Apply exponential recency decay to all active/decaying principles.

  Formula: `recency_score = 2^(-days / effective_half_life)`
  where `effective_half_life = half_life / (1 + log(frequency))`

  Higher frequency = slower decay.

  Returns `{:ok, count}` of principles updated.
  """
  @spec apply_decay() :: {:ok, non_neg_integer()}
  def apply_decay do
    config = Application.get_env(:cerno, :decay, [])
    half_life = Keyword.get(config, :half_life_days, 90)
    now = DateTime.utc_now()

    principles =
      from(p in Principle, where: p.status in [:active, :decaying])
      |> Repo.all()

    count =
      Enum.reduce(principles, 0, fn principle, acc ->
        days_since = DateTime.diff(now, principle.updated_at, :day)
        effective_half_life = half_life / (1 + :math.log(max(principle.frequency, 1)))
        new_recency = :math.pow(2, -days_since / effective_half_life)
        new_recency = max(min(new_recency, 1.0), 0.0)

        if abs(new_recency - principle.recency_score) > 0.001 do
          principle
          |> Principle.changeset(%{recency_score: new_recency})
          |> Repo.update!()

          acc + 1
        else
          acc
        end
      end)

    Logger.info("Decay: #{count} principles updated")
    {:ok, count}
  end

  @doc """
  Recompute rank for all active/decaying principles using current link counts.

  Returns `{:ok, count}` of principles updated.
  """
  @spec recompute_ranks() :: {:ok, non_neg_integer()}
  def recompute_ranks do
    principles =
      from(p in Principle, where: p.status in [:active, :decaying])
      |> Repo.all()

    count =
      Enum.reduce(principles, 0, fn principle, acc ->
        link_count =
          from(l in PrincipleLink,
            where: l.source_id == ^principle.id or l.target_id == ^principle.id
          )
          |> Repo.aggregate(:count)

        new_rank = Principle.compute_rank(principle, link_count)

        if abs(new_rank - principle.rank) > 0.001 do
          principle
          |> Principle.changeset(%{rank: new_rank})
          |> Repo.update!()

          acc + 1
        else
          acc
        end
      end)

    Logger.info("Rank recomputation: #{count} principles updated")
    {:ok, count}
  end

  @doc """
  Apply pruning rules to transition principle status.

  - rank < decay_threshold (0.15) + stale > stale_days_decay (90d) → `:decaying`
  - rank < prune_threshold (0.10) + stale > stale_days_prune (180d) → `:pruned`

  Returns `{:ok, %{decaying: count, pruned: count}}`.
  """
  @spec apply_pruning() :: {:ok, %{decaying: non_neg_integer(), pruned: non_neg_integer()}}
  def apply_pruning do
    config = Application.get_env(:cerno, :decay, [])
    decay_threshold = Keyword.get(config, :decay_threshold, 0.15)
    prune_threshold = Keyword.get(config, :prune_threshold, 0.10)
    stale_days_decay = Keyword.get(config, :stale_days_decay, 90)
    stale_days_prune = Keyword.get(config, :stale_days_prune, 180)

    now = DateTime.utc_now()
    decay_cutoff = DateTime.add(now, -stale_days_decay, :day)
    prune_cutoff = DateTime.add(now, -stale_days_prune, :day)

    # Prune first (stricter), then decay (less strict)
    {pruned_count, _} =
      from(p in Principle,
        where: p.status in [:active, :decaying],
        where: p.rank < ^prune_threshold,
        where: p.updated_at < ^prune_cutoff
      )
      |> Repo.update_all(set: [status: :pruned])

    {decaying_count, _} =
      from(p in Principle,
        where: p.status == :active,
        where: p.rank < ^decay_threshold,
        where: p.updated_at < ^decay_cutoff
      )
      |> Repo.update_all(set: [status: :decaying])

    Logger.info("Pruning: #{decaying_count} → decaying, #{pruned_count} → pruned")
    {:ok, %{decaying: decaying_count, pruned: pruned_count}}
  end
end
