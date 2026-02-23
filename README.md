# Cerno

[![CI](https://github.com/dimitar/Cerno/actions/workflows/ci.yml/badge.svg)](https://github.com/dimitar/Cerno/actions/workflows/ci.yml)
[![Coverage Status](https://coveralls.io/repos/github/dimitar/Cerno/badge.svg?branch=main)](https://coveralls.io/github/dimitar/Cerno?branch=main)
[![License: AGPL-3.0](https://img.shields.io/badge/License-AGPL--3.0-blue.svg)](LICENSE)
[![Elixir](https://img.shields.io/badge/Elixir-1.19-purple.svg)](https://elixir-lang.org/)
[![GitHub stars](https://img.shields.io/github/stars/dimitar/Cerno)](https://github.com/dimitar/Cerno/stargazers)
[![GitHub issues](https://img.shields.io/github/issues/dimitar/Cerno)](https://github.com/dimitar/Cerno/issues)

*Latin: "I sift, I separate, I decide" — the root of discernment.*

Cerno is a bidirectional memory system for AI agents. It governs the accumulation, sorting, linking, and ranking of knowledge across layered memory stores — from atomic project files up to long-term wisdom, and back down again.

## The Problem

AI agents accumulate knowledge in scattered, session-scoped files (like `CLAUDE.md`, `.cursorrules`, etc.). This knowledge is:

- **Fragmented** — spread across projects with no cross-pollination
- **Contradictory** — conflicting learnings from different contexts coexist unresolved
- **Unranked** — a one-off observation carries the same weight as a battle-tested principle
- **One-directional** — knowledge flows in but rarely flows back out in a useful, context-aware form

## The Model

Cerno organises knowledge into three layers, with processes governing the flow between them.

```
Atomic Memory ──accumulate──▶ Short-Term Memory ──distil──▶ Long-Term Memory
     ◀──resolve───                    ◀──recall──
```

### Layer 1: Atomic Memory

The working memory of a single project or task. Files like `CLAUDE.md` that contain context-specific rules, principles, and conventions. This is the **attention layer** — what the agent focuses on right now.

- Scoped to a single project or task
- Directly consumed by the agent during execution
- The most concrete, actionable layer
- **Agent-agnostic input:** pluggable parsers handle different formats (`CLAUDE.md`, `.cursorrules`, etc.)

### Layer 2: Short-Term Memory

A collective grouping across atomic memory files. This layer aggregates knowledge from multiple projects and sessions. It is expected to contain duplication, contradiction, and varying levels of confidence.

A **reconciliation process** runs at this layer which:

- Deduplicates overlapping knowledge (exact hash + semantic embedding similarity)
- Flags contradictions for resolution
- Clusters related observations into emerging patterns
- Adjusts confidence based on frequency, recency, and cross-project validation

### Layer 3: Long-Term Memory

The fully rationalised collection of short-term memories accumulated over time. This is where observations crystallise into:

- **Learnings** — verified patterns and techniques
- **Principles** — general rules derived from repeated experience
- **Morals** — hard-won lessons from failures and edge cases

An **organisation process** at this layer:

- Ranks knowledge by confidence, frequency, and recency
- Links related concepts across domains
- Prunes outdated or superseded knowledge
- Resolves accumulated wisdom back downward into atomic files when a relevant task is being worked on

## Agent-Specific I/O

Cerno is agent-agnostic at its core. Both input and output adapt per agent:

- **Input:** Pluggable parsers (`Cerno.Atomic.Parser` behaviour) handle each agent's context file format
- **Output:** Pluggable formatters (`Cerno.Formatter` behaviour) render resolved knowledge into the right format for each agent

## Tech Stack

| Component | Technology |
|-----------|-----------|
| Language | Elixir 1.19 / OTP 28 |
| Database | PostgreSQL 18 + pgvector (HNSW indexes) |
| Web | Phoenix 1.7 (PubSub, REST API) |
| Embeddings | Pluggable — OpenAI text-embedding-3-small (default) |
| Interface | CLI (escript) + REST API |

## Getting Started

### Prerequisites

- Elixir 1.19+
- Erlang/OTP 28+
- PostgreSQL with [pgvector](https://github.com/pgvector/pgvector) extension

### Setup

```bash
git clone https://github.com/dimitar/Cerno.git
cd Cerno
mix deps.get
mix ecto.setup    # Creates database and runs migrations
mix test          # 166 tests, 0 failures
```

### CLI Usage

```bash
cerno init <path>              # Register a project for watching
cerno scan [<path>]            # Scan for context file changes
cerno resolve <path> [--dry-run]  # Resolve principles into a context file
cerno status                   # Show system status
cerno insights                 # List short-term insights
cerno principles               # List long-term principles
cerno reconcile                # Trigger reconciliation
cerno organise                 # Trigger organisation
```

## Contributing

See **[CONTRIBUTING.md](CONTRIBUTING.md)** for development setup, coding conventions, and PR guidelines.

## Documentation

- **[ARCHITECTURE.md](ARCHITECTURE.md)** — Current implementation status, module inventory, what's built vs remaining
- **[docs/DESIGN.md](docs/DESIGN.md)** — Original architecture specification from the planning phase
- **[docs/ELIXIR_FOR_OOP_DEVS.md](docs/ELIXIR_FOR_OOP_DEVS.md)** — Elixir guide for developers coming from Java/C#

## Status

Phases 1–5 complete. Phase 6 (Polish) next.

| Phase | Description | Status |
|-------|-------------|--------|
| 1. Foundation | Project setup, data models, OTP tree, schema, CLI | Done |
| 2. Accumulation | Embedding persistence, semantic dedup, contradiction detection, file watcher | Done |
| 3. Reconciliation | Clustering, intra-cluster dedup, contradiction scan, confidence adjustment | Done |
| 4. Organisation | Insight → Principle promotion, linking, ranking, lifecycle | Done |
| 5. Resolution | Principle retrieval, filtering, conflict detection, context-aware injection | Done |
| 6. Polish | Daemon mode, REST API, additional parsers/formatters | Planned |
