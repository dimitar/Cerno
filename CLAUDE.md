# CLAUDE.md — Cerno

## Project Overview

Cerno is a bidirectional memory system for AI agents, built in Elixir/OTP. Knowledge from per-project context files (`CLAUDE.md`, `.cursorrules`, etc.) accumulates upward through three layers and resolves back downward into working memory.

**Stack:** Elixir 1.19, OTP 28, Phoenix 1.7, Ecto, PostgreSQL 18 + pgvector.

## Architecture

Three layers with four processes connecting them:

1. **Atomic** (`lib/cerno/atomic/`) — In-memory Fragments parsed from context files. Pluggable parsers per agent format.
2. **Short-Term** (`lib/cerno/short_term/`) — Insights in Postgres. Deduplicated, tagged, contradiction-aware.
3. **Long-Term** (`lib/cerno/long_term/`) — Principles in Postgres. Ranked, linked, distilled from insights.

**Processes** (`lib/cerno/process/`): Accumulator → Reconciler → Organiser, plus Resolver for downward flow. Connected via Phoenix PubSub.

See [ARCHITECTURE.md](ARCHITECTURE.md) for full details. See [docs/DESIGN.md](docs/DESIGN.md) for the original specification.

## Project Structure

```
lib/cerno/
├── atomic/           Fragment struct, Parser behaviour, ClaudeMd parser
├── short_term/       Insight, InsightSource, Contradiction, Cluster, Classifier
├── long_term/        Principle, Derivation, PrincipleLink schemas
├── process/          Accumulator, Reconciler, Organiser, Resolver GenServers
├── embedding/        Embedding behaviour, OpenAI provider, Mock, Pool, Cache
├── watcher/          FileWatcher (polling GenServer per project)
├── formatter/        Formatter behaviour, Claude formatter
├── application.ex    OTP supervision tree
├── repo.ex           Ecto Repo
├── postgrex_types.ex Pgvector type registration
├── accumulation_run.ex  Audit logging for scans
├── watched_project.ex
└── cli.ex
config/               Environment configs (dev, test, runtime)
priv/repo/migrations/ Postgres schema (pgvector, HNSW indexes)
test/                 ExUnit tests (74 passing)
```

## Design Principles

- **Bidirectionality is the defining constraint.** Every data structure must support both upward accumulation and downward resolution.
- **Agent-agnostic storage, agent-specific I/O.** Parsers adapt input per agent format; formatters adapt output. The memory store is universal.
- **Knowledge has weight.** Confidence, frequency, recency, and source quality all factor into ranking.
- **Contradiction is expected.** Detected and resolved explicitly, never silently prevented.
- **Pluggable interfaces.** Behaviours for parsers, embeddings, and formatters. New agents = new implementation, not new architecture.

## Coding Conventions

- **Behaviours for extension points.** `Cerno.Atomic.Parser`, `Cerno.Embedding`, `Cerno.Formatter` — implement callbacks, register, done.
- **GenServers for stateful processes.** Accumulator, Reconciler, Organiser, Resolver each own their lifecycle. Mutual exclusion via state flags. Async work via Task.Supervisor.
- **PubSub for coordination.** Processes communicate via Phoenix.PubSub topics, not direct calls.
- **Ecto schemas with changesets.** All DB types use explicit changesets with validation. Enums via `Ecto.Enum`.
- **Keep modules small.** One schema per file, one process per file.
- **Tests don't need Postgres** for pure logic. DB-backed tests use Ecto sandbox with `Cerno.Embedding.Mock` for deterministic embeddings.

## Running

```bash
# Windows: Elixir and Erlang must be on PATH
export PATH="/c/Program Files/Erlang OTP/bin:/c/Program Files/Erlang OTP/erts-16.2.1/bin:/c/Program Files/Elixir/bin:$PATH"

mix deps.get          # Fetch dependencies
mix ecto.setup        # Create DB + run migrations (needs Postgres with pgvector)
mix compile           # Compile (should be 0 warnings)
mix test              # Run tests (74 passing)
```

**Database:** Postgres password is configured in `config/dev.exs` and `config/test.exs`.

## Current Phase

Phases 1 (Foundation) and 2 (Accumulation Pipeline) are complete. Next: Phase 3 (Reconciliation).

Phase 2 delivered: full accumulation pipeline with file hash comparison, exact + semantic dedup (pgvector HNSW at 0.92 threshold), heuristic classification, contradiction detection (0.5–0.85 range), accumulation run audit logging, and polling file watcher with PubSub integration.
