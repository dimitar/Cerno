# Cerno Architecture Design

> Original specification produced during the planning phase (2026-02-22).
> For current implementation status, see [ARCHITECTURE.md](../ARCHITECTURE.md).

## Context

Cerno is a bidirectional memory system for AI agents. Knowledge fragments from per-project CLAUDE.md files accumulate upward through three layers (Atomic → Short-Term → Long-Term) and resolve back downward into working memory for new tasks. This design establishes the data models, storage architecture, core processes, and Elixir/OTP system structure.

## Confirmed Decisions

- **Storage split:** Files for atomic (CLAUDE.md), Postgres+pgvector for short-term and long-term
- **Language:** Elixir (OTP supervision trees, Ecto, Phoenix)
- **Embeddings:** Pluggable — API (OpenAI/Voyage) or local (Nx/Bumblebee) behind a behaviour
- **Agent output:** Agent-agnostic from day one — pluggable formatters (Claude, ChatGPT, Cursor, etc.)
- **Interface:** CLI + background daemon + REST API
- **Triggers:** Flexible — CLI, git hooks, file watching, periodic scan

---

## 1. Data Models

### Knowledge Unit Taxonomy

```
Observation (abstract)
  ├── Fragment     (Atomic: raw text chunk from CLAUDE.md, in-memory only)
  ├── Insight      (Short-term: deduplicated, tagged, contradiction-aware, in Postgres)
  └── Principle    (Long-term: ranked, linked, distilled, in Postgres)
```

### Fragment (in-memory struct, not persisted)

| Field | Type | Purpose |
|-------|------|---------|
| id | string | Deterministic hash of source_path + content (change detection) |
| content | string | Raw text of the markdown section |
| source_path | string | Absolute path to the CLAUDE.md file |
| source_project | string | Project identifier derived from path |
| section_heading | string? | H2 heading this was extracted under |
| line_range | {int, int} | Start and end line in source file |
| file_hash | string | Hash of entire file at extraction time |
| extracted_at | datetime | When parsed |

### Insight (Postgres — `insights` table)

| Field | Type | Purpose |
|-------|------|---------|
| content | text | Normalized text |
| content_hash | string | SHA-256 for exact dedup |
| embedding | vector(1536) | For semantic search/dedup |
| category | enum | convention, principle, technique, warning, preference, fact, pattern |
| tags | string[] | Freeform tags |
| domain | string | e.g., "elixir", "testing", "architecture" |
| confidence | float | 0.0–1.0 |
| observation_count | int | How many fragments contributed |
| first_seen_at / last_seen_at | datetime | Recency tracking |
| status | enum | active, contradicted, superseded, pending_review |

**Relations:**
- has_many `InsightSource` — traces back to original file, project, line range, fragment_id
- has_many `Contradiction` — first-class entities with resolution lifecycle (direct/partial/contextual, unresolved → resolved)
- many_to_many `Cluster` — semantic groupings with centroid and coherence score

### Principle (Postgres — `principles` table)

| Field | Type | Purpose |
|-------|------|---------|
| content | text | Distilled statement |
| elaboration | text | Longer explanation/context |
| content_hash | string | For exact dedup |
| embedding | vector(1536) | For semantic search |
| category | enum | learning, principle, moral, heuristic, anti_pattern |
| tags | string[] | Freeform tags |
| domains | string[] | Can span multiple domains |
| confidence | float | Weighted score |
| frequency | int | Total observation count across all sources |
| recency_score | float | Exponentially decayed score |
| source_quality | float | Weighted quality of contributing sources |
| rank | float | Composite score: confidence(35%) + frequency(25%) + recency(20%) + quality(15%) + links(5%) |
| status | enum | active → decaying → pruned (archived, not deleted) |

**Relations:**
- has_many `Derivation` — links to source insights with contribution weight (full traceability)
- has_many `PrincipleLink` — typed relationships: reinforces, generalizes, specializes, contradicts, depends_on, related (with strength 0-1)

---

## 2. Postgres Schema

Key tables: `insights`, `insight_sources`, `contradictions`, `clusters`, `cluster_insights`, `principles`, `derivations`, `principle_links`, `watched_projects`, `accumulation_runs`, `resolution_runs`, `embedding_model_config`.

**Indexes:**
- HNSW vector indexes on `insights.embedding` and `principles.embedding` (cosine ops, m=16, ef_construction=64)
- GIN indexes on tags and domains arrays
- Unique constraint on contradiction pairs using LEAST/GREATEST to prevent (A,B)/(B,A) duplicates
- Unique constraint on `insight_sources.fragment_id` to prevent re-processing

**Vector dimension flexibility:** Dimension configured in app config. Model change triggers re-embedding migration as background job. `embedding_model_config` table tracks active model.

---

## 3. Core Processes

### Accumulation (Upward: Files → Short-Term → Long-Term)

1. **Discovery** — Scan project paths for CLAUDE.md files, compare file hashes, skip unchanged
2. **Parsing** — Split by H2 headings into Fragments. Nested CLAUDE.md files parsed independently with subdirectory context.
3. **Exact dedup** — content_hash match → update counts, add source, done
4. **Semantic dedup** — embedding similarity > 0.92 → merge, update counts, done
5. **New insight** — Create record, classify category, extract tags/domain
6. **Contradiction check** — Query similarity range 0.5–0.85, run layered detection (negation heuristic → embedding flagging → LLM classification)

### Reconciliation (Within Short-Term)

1. Re-cluster all active insights (DBSCAN/k-means)
2. Intra-cluster dedup (lower threshold 0.88)
3. Cross-cluster contradiction scan
4. Confidence adjustment (multi-project ↑, stale ↓, contradicted ↓)
5. Flag promotion candidates (confidence > 0.7, observations >= 3, no unresolved contradictions, age > 7 days)

### Organisation (Short-Term → Long-Term)

1. Distil: single insight promotes directly; cluster gets LLM-synthesized
2. Dedup against existing principles (hash then embedding)
3. Link detection and classification
4. Rank computation
5. Pruning: active → decaying (rank < 0.15, stale > 90d) → pruned (rank < 0.10, stale > 180d)

### Resolution (Downward: Long-Term → Files)

1. Parse current CLAUDE.md, compute embeddings
2. Retrieve relevant principles: 50% semantic similarity + 30% rank + 20% domain match
3. Filter out already-represented principles, flag contradictions
4. Format per agent type (pluggable formatter)
5. Inject into dedicated `## Resolved Knowledge from Cerno` section — never overwrite human content

---

## 4. Elixir/OTP Architecture

### Supervision Tree

```
Cerno.Application
  ├── Cerno.Repo (Ecto — Postgres pool)
  ├── Cerno.EmbeddingSupervisor
  │     ├── Embedding.Pool (GenServer — batches requests)
  │     └── Embedding.Cache (ETS-backed)
  ├── Cerno.WatcherSupervisor (DynamicSupervisor)
  │     ├── Watcher.FileWatcher (GenServer per project)
  │     └── Watcher.ScheduledScanner (GenServer)
  ├── Cerno.ProcessSupervisor
  │     ├── Process.Accumulator (GenServer)
  │     ├── Process.Reconciler (GenServer)
  │     ├── Process.Organiser (GenServer)
  │     ├── Process.Resolver (GenServer)
  │     └── Process.TaskSupervisor (Task.Supervisor)
  ├── Cerno.API.Endpoint (Phoenix REST/JSON)
  └── Cerno.PubSub (Phoenix.PubSub)
```

### Event Flow (PubSub)

- `file:changed` → Watcher → Accumulator
- `accumulation:complete` → Accumulator → Reconciler
- `reconciliation:complete` → Reconciler → Organiser
- `resolution:requested` → CLI/API → Resolver

### Pluggable Behaviours

- `Cerno.Embedding` — `embed/1`, `embed_batch/1`, `dimension/0`
- `Cerno.Formatter` — `format_sections/2`, `max_output_tokens/0`

### CLI

```
cerno init <path>       cerno scan [<path>]      cerno resolve <path> [--agent=X --dry-run]
cerno status            cerno insights           cerno principles
cerno reconcile         cerno organise           cerno daemon start|stop|status
```

---

## 5. Technical Challenges & Mitigations

| Challenge | Mitigation |
|-----------|------------|
| Semantic dedup thresholds are domain-dependent | Per-category configurable thresholds, log all decisions, `cerno calibrate` command |
| Contradiction detection requires semantic understanding | Layered: negation heuristics (cheap) → embedding flagging (medium) → LLM classification (expensive, budget-capped) |
| Knowledge decay vs timeless principles | Frequency-weighted half-life: `effective_lambda = lambda / (1 + log(frequency))` |
| Embedding drift on model change | Track model version, full re-embedding migration as background job, disable cross-model comparisons during migration |
| Resolution conflicts with human-written content | Never overwrite, dedicated section, `[CONFLICT]` markers, `--dry-run` mode |
| Concurrent accumulation race conditions | GenServer serializes per-project, DB advisory locks, unique constraints as safety net |

---

## 6. Implementation Phases

### Phase 1: Foundation
- Elixir project setup (Mix, Ecto, Phoenix)
- Postgres schema migrations (all tables, indexes, pgvector)
- Embedding behaviour + OpenAI provider
- CLAUDE.md parser (Fragment extraction)
- Basic CLI skeleton (`cerno init`, `cerno scan`)

### Phase 2: Accumulation Pipeline
- Fragment → Insight ingestion with exact + semantic dedup
- InsightSource tracking
- File watcher GenServer
- Accumulation run logging

### Phase 3: Reconciliation
- Contradiction detection (negation heuristic + embedding-based)
- Semantic clustering
- Confidence adjustment
- Promotion candidate identification

### Phase 4: Organisation & Long-Term
- Insight → Principle promotion
- Rank computation
- Cross-domain linking
- Decay and pruning

### Phase 5: Resolution
- Principle retrieval by context
- Coverage checking
- Claude formatter (first agent)
- File injection with conflict detection

### Phase 6: Polish & Extension
- Background daemon mode
- Full API endpoints
- Additional formatters (ChatGPT, Cursor)
- Local embedding provider (Bumblebee)
- Scheduled scan/reconciliation

---

## 7. Key Files to Create

| File | Purpose |
|------|---------|
| `lib/cerno/application.ex` | OTP application, supervision tree |
| `priv/repo/migrations/001_create_core_schema.exs` | Full Postgres schema |
| `lib/cerno/embedding.ex` | Embedding behaviour (callback spec) |
| `lib/cerno/embedding/openai.ex` | OpenAI embedding provider |
| `lib/cerno/atomic/parser.ex` | CLAUDE.md → Fragment parser |
| `lib/cerno/atomic/fragment.ex` | Fragment struct |
| `lib/cerno/short_term/insight.ex` | Insight Ecto schema |
| `lib/cerno/short_term/insight_source.ex` | InsightSource Ecto schema |
| `lib/cerno/short_term/contradiction.ex` | Contradiction Ecto schema |
| `lib/cerno/short_term/cluster.ex` | Cluster Ecto schema |
| `lib/cerno/long_term/principle.ex` | Principle Ecto schema |
| `lib/cerno/long_term/derivation.ex` | Derivation Ecto schema |
| `lib/cerno/long_term/principle_link.ex` | PrincipleLink Ecto schema |
| `lib/cerno/process/accumulator.ex` | Accumulation GenServer |
| `lib/cerno/process/reconciler.ex` | Reconciliation GenServer |
| `lib/cerno/process/organiser.ex` | Organisation GenServer |
| `lib/cerno/process/resolver.ex` | Resolution GenServer |
| `lib/cerno/formatter.ex` | Formatter behaviour |
| `lib/cerno/formatter/claude.ex` | Claude CLAUDE.md formatter |
| `lib/cerno_cli.ex` | CLI entry point |

## 8. Verification

- **Unit tests:** Parser produces correct fragments from sample CLAUDE.md files
- **Integration tests:** Full accumulation pipeline with test Postgres (Ecto sandbox)
- **Dedup verification:** Ingest duplicate content, verify single insight created
- **Contradiction test:** Ingest contradictory statements, verify Contradiction record created
- **Resolution test:** Resolve principles into a test CLAUDE.md, verify formatting and no overwrites
- **End-to-end:** Register a project, scan, reconcile, organise, resolve — verify the full cycle
