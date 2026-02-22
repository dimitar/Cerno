# Cerno Architecture

*Last updated: 2026-02-22*

Cerno is a bidirectional memory system for AI agents. Knowledge fragments from per-project `CLAUDE.md` files accumulate upward through three layers and resolve back downward into working memory for new tasks.

```
Atomic Memory ──accumulate──▶ Short-Term Memory ──distil──▶ Long-Term Memory
     ◀──resolve───                    ◀──recall──
```

## Technology Stack

| Component | Technology |
|-----------|-----------|
| Language | Elixir 1.19 / OTP 28 |
| Database | PostgreSQL 18 + pgvector |
| Web | Phoenix 1.7 (REST/JSON, PubSub) |
| Embeddings | Pluggable — OpenAI text-embedding-3-small (1536D) |
| HTTP Client | Req |
| CLI | Escript |

---

## The Three Layers

### 1. Atomic Memory — `Cerno.Atomic`

The working memory of a single project. Raw text extracted from `CLAUDE.md` files.

**Key type: `Fragment`** — an in-memory struct (not persisted) representing one section of a `CLAUDE.md` file, split by H2 headings.

```
Fragment
├── id            deterministic SHA-256(source_path + content)
├── content       raw markdown text of the section
├── source_path   absolute path to the CLAUDE.md
├── source_project  project name derived from directory
├── section_heading  H2 heading text (nil for preamble)
├── line_range    {start_line, end_line}
├── file_hash     SHA-256 of the entire file
└── extracted_at  UTC timestamp
```

**Modules:**

| Module | Purpose | Status |
|--------|---------|--------|
| `Cerno.Atomic.Fragment` | Struct definition, deterministic ID generation | Complete |
| `Cerno.Atomic.Parser` | `CLAUDE.md` → list of Fragments. Splits on H2 headings, tracks line ranges, supports recursive directory scanning | Complete |

### 2. Short-Term Memory — `Cerno.ShortTerm`

Aggregated knowledge across projects. Contains deduplication, contradiction tracking, and semantic clustering. Stored in Postgres.

**Key type: `Insight`** — a deduplicated, tagged, contradiction-aware knowledge unit.

```
Insight (Postgres: insights)
├── content / content_hash    text + SHA-256 for exact dedup
├── embedding                 vector(1536) for semantic operations
├── category                  convention | principle | technique | warning | preference | fact | pattern
├── tags[]                    freeform labels
├── domain                    e.g. "elixir", "testing"
├── confidence                0.0–1.0
├── observation_count         how many fragments contributed
├── first_seen_at / last_seen_at
├── status                    active | contradicted | superseded | pending_review
├── ── has_many ──▶ InsightSource    provenance back to source files
├── ── has_many ──▶ Contradiction    detected conflicts with other insights
└── ── many_to_many ──▶ Cluster      semantic groupings
```

**Supporting types:**

| Type | Table | Purpose |
|------|-------|---------|
| `InsightSource` | `insight_sources` | Links insight → original file, project, line range, fragment ID. Unique on `fragment_id` to prevent reprocessing. |
| `Contradiction` | `contradictions` | Pair of conflicting insights with type (direct/partial/contextual), resolution lifecycle (unresolved → resolved/dismissed), and similarity score. Unique pair constraint via `LEAST/GREATEST`. |
| `Cluster` | `clusters` | Semantic grouping with centroid embedding and coherence score. Many-to-many with insights via `cluster_insights`. |

**Modules:**

| Module | Purpose | Status |
|--------|---------|--------|
| `Cerno.ShortTerm.Insight` | Ecto schema, changeset, `hash_content/1` | Complete |
| `Cerno.ShortTerm.InsightSource` | Ecto schema, changeset | Complete |
| `Cerno.ShortTerm.Contradiction` | Ecto schema, changeset | Complete |
| `Cerno.ShortTerm.Cluster` | Ecto schema, changeset | Complete |

### 3. Long-Term Memory — `Cerno.LongTerm`

Distilled, ranked, linked knowledge. Principles are derived from insights via the organisation process.

**Key type: `Principle`** — a ranked, linked knowledge unit.

```
Principle (Postgres: principles)
├── content / elaboration     concise statement + longer explanation
├── content_hash / embedding  dedup + semantic operations
├── category                  learning | principle | moral | heuristic | anti_pattern
├── tags[] / domains[]        can span multiple domains
├── confidence                0.0–1.0
├── frequency                 total observation count across sources
├── recency_score             exponentially decayed (0.0–1.0)
├── source_quality            weighted quality of contributing sources
├── rank                      composite: confidence(35%) + frequency(25%) + recency(20%) + quality(15%) + links(5%)
├── status                    active → decaying → pruned
├── ── has_many ──▶ Derivation       links to source insights with contribution weight
└── ── has_many ──▶ PrincipleLink    typed edges: reinforces | generalizes | specializes | contradicts | depends_on | related
```

**Supporting types:**

| Type | Table | Purpose |
|------|-------|---------|
| `Derivation` | `derivations` | Traceability: principle ← insight with contribution weight (0–1). Unique on pair. |
| `PrincipleLink` | `principle_links` | Typed, weighted edges between principles (strength 0–1). Unique on (source, target, type). |

**Modules:**

| Module | Purpose | Status |
|--------|---------|--------|
| `Cerno.LongTerm.Principle` | Ecto schema, changeset, `compute_rank/2` with configurable weights | Complete |
| `Cerno.LongTerm.Derivation` | Ecto schema, changeset | Complete |
| `Cerno.LongTerm.PrincipleLink` | Ecto schema, changeset | Complete |

---

## Core Processes

Four GenServers form the processing pipeline, connected via Phoenix PubSub events:

```
file:changed ──▶ Accumulator ──accumulation:complete──▶ Reconciler ──reconciliation:complete──▶ Organiser
                                                                                                    │
resolution:requested ──▶ Resolver ◀─────────────────────────────────────────────────────────────────┘
```

### Accumulator — `Cerno.Process.Accumulator`

Drives the upward flow from files to short-term memory.

**Current implementation:**
1. Receive path (via PubSub `file:changed`, CLI `scan`, or `scan_all`)
2. Skip if already processing that path (MapSet-based lock)
3. Parse `CLAUDE.md` → Fragments via `Cerno.Atomic.Parser`
4. For each fragment, compute `content_hash`:
   - **Exact match found** → increment `observation_count`, update `last_seen_at`, add `InsightSource`
   - **No match** → create new `Insight` with default confidence 0.5, add `InsightSource`
5. Broadcast `accumulation:complete` on PubSub

**Not yet implemented:**
- Semantic dedup (embedding similarity > 0.92 threshold)
- Embedding generation and persistence on Insight records
- Category/tag/domain classification
- Contradiction detection during ingestion
- File hash comparison to skip unchanged files
- Accumulation run audit logging

### Reconciler — `Cerno.Process.Reconciler`

Runs reconciliation within the short-term layer. Auto-triggered after accumulation completes.

**Current implementation:** Framework only — GenServer with mutual exclusion (`running` flag), PubSub subscription, and task delegation. The `run_reconciliation/0` function is a stub.

**Planned implementation (Phase 3):**
1. Re-cluster all active insights using embedding similarity (DBSCAN or k-means)
2. Intra-cluster dedup at lower threshold (0.88)
3. Cross-cluster contradiction scan using layered detection:
   - Negation heuristics (cheap) → embedding flagging (medium) → LLM classification (expensive, budget-capped)
4. Confidence adjustment: multi-project observations ↑, stale ↓, contradicted ↓
5. Flag promotion candidates: confidence > 0.7, observations >= 3, no unresolved contradictions, age > 7 days

### Organiser — `Cerno.Process.Organiser`

Promotes insights to principles (short-term → long-term). Auto-triggered after reconciliation completes.

**Current implementation:** Framework only — same pattern as Reconciler.

**Planned implementation (Phase 4):**
1. Distil: single insight promotes directly; insight clusters get LLM-synthesized into a principle
2. Dedup against existing principles (content hash, then embedding similarity)
3. Link detection and classification (reinforces, generalizes, etc.)
4. Rank computation via `Principle.compute_rank/2`
5. Pruning lifecycle: active → decaying (rank < 0.15, stale > 90d) → pruned (rank < 0.10, stale > 180d)

### Resolver — `Cerno.Process.Resolver`

Drives the downward flow from long-term memory back into `CLAUDE.md` files.

**Current implementation:**
- File I/O: reads target `CLAUDE.md`, replaces or appends the `## Resolved Knowledge from Cerno` section (never overwrites human content)
- Formatter integration: delegates to pluggable formatter (default: Claude)
- Dry-run mode: returns formatted text without writing
- Currently resolves with an empty principles list (retrieval not implemented)

**Planned implementation (Phase 5):**
1. Parse current `CLAUDE.md` and compute embeddings for existing content
2. Retrieve relevant principles: 50% semantic similarity + 30% rank + 20% domain match
3. Filter out already-represented principles, flag contradictions with `[CONFLICT]` markers
4. Format per agent type via pluggable formatter
5. Inject into dedicated section

---

## Embedding Subsystem — `Cerno.Embedding`

Pluggable embedding system with batching and caching.

```
Cerno.Embedding (behaviour)
├── embed/1          single text → vector
├── embed_batch/1    multiple texts → vectors
└── dimension/0      vector dimension (1536)

Cerno.Embedding.OpenAI    OpenAI API provider (text-embedding-3-small)
Cerno.Embedding.Pool      GenServer that batches requests (20 items or 500ms flush)
Cerno.Embedding.Cache     ETS-backed LRU cache (10,000 entries, SHA-256 keys)
```

The behaviour is implemented by `Cerno.Embedding.OpenAI`. Additional providers (Voyage, Nx/Bumblebee for local inference) can be added by implementing the three callbacks.

Configuration in `config.exs` selects the provider and dimension. The test environment uses `Cerno.Embedding.Mock` (not yet implemented — intended for Mox).

---

## Formatter Subsystem — `Cerno.Formatter`

Agent-agnostic storage, agent-specific output. Formatters adapt resolved principles for different AI agents.

```
Cerno.Formatter (behaviour)
├── format_sections/2     principles + opts → formatted text
└── max_output_tokens/0   output size budget

Cerno.Formatter.Claude    CLAUDE.md markdown formatter
```

The Claude formatter:
- Groups principles by primary domain
- Sorts by rank descending within groups
- Produces markdown with `### Domain` headings and bullet points
- Optionally includes metadata (confidence, rank) with `include_metadata: true`
- Wraps in a `## Resolved Knowledge from Cerno` section with a "do not edit" notice

**Planned formatters:** ChatGPT (system prompt format), Cursor (`.cursorrules` format).

---

## OTP Supervision Tree

```
Cerno.Application (one_for_one)
├── Cerno.Repo                              Ecto PostgreSQL pool
├── {Phoenix.PubSub, name: Cerno.PubSub}    Event bus for process coordination
├── Cerno.Embedding.Pool                     Batched embedding requests
├── Cerno.Embedding.Cache                    ETS embedding cache
├── DynamicSupervisor (Cerno.Watcher.Supervisor)   File watchers (not yet populated)
├── Task.Supervisor (Cerno.Process.TaskSupervisor)  Async work within processes
├── Cerno.Process.Accumulator                Files → Short-Term
├── Cerno.Process.Reconciler                 Short-Term reconciliation
├── Cerno.Process.Organiser                  Short-Term → Long-Term
└── Cerno.Process.Resolver                   Long-Term → Files
```

---

## Database Schema

PostgreSQL 18 with pgvector extension. 12 tables created in a single migration.

### Tables

| Table | Layer | Purpose |
|-------|-------|---------|
| `insights` | Short-Term | Deduplicated knowledge units |
| `insight_sources` | Short-Term | Provenance: insight ← source file |
| `contradictions` | Short-Term | Conflict pairs with resolution lifecycle |
| `clusters` | Short-Term | Semantic groupings |
| `cluster_insights` | Short-Term | Join table |
| `principles` | Long-Term | Ranked, linked knowledge |
| `derivations` | Long-Term | Traceability: principle ← insights |
| `principle_links` | Long-Term | Typed edges between principles |
| `watched_projects` | Operations | Monitored project registry |
| `accumulation_runs` | Operations | Audit log for scans |
| `resolution_runs` | Operations | Audit log for resolutions |
| `embedding_model_config` | Operations | Tracks active embedding model/version |

### Indexes

- **HNSW** (pgvector) on `insights.embedding` and `principles.embedding` — fast approximate nearest neighbour search (cosine similarity, m=16, ef_construction=64)
- **GIN** on `insights.tags`, `principles.tags`, `principles.domains` — fast array containment queries
- **Unique** on `insights.content_hash`, `principles.content_hash` — exact dedup at DB level
- **Unique** on `contradictions(LEAST(a,b), GREATEST(a,b))` — prevents (A,B)/(B,A) duplicate pairs
- **Unique** on `insight_sources.fragment_id` — prevents reprocessing the same fragment
- **Unique** on `derivations(principle_id, insight_id)` and `principle_links(source_id, target_id, link_type)`

---

## CLI — `Cerno.CLI`

Escript-based command interface. All commands dispatch to the appropriate GenServer or Repo query.

| Command | What it does | Status |
|---------|-------------|--------|
| `cerno init <path>` | Register a project as a `WatchedProject` | Working |
| `cerno scan [<path>]` | Trigger accumulation for one or all projects | Working |
| `cerno resolve <path> [--dry-run]` | Resolve principles into a `CLAUDE.md` | Working (empty output — no principles yet) |
| `cerno status` | Show watched project count | Working |
| `cerno insights` | List top 20 active insights by confidence | Working |
| `cerno principles` | List top 20 active principles by rank | Working |
| `cerno reconcile` | Trigger reconciliation | Working (stub process) |
| `cerno organise` | Trigger organisation | Working (stub process) |
| `cerno daemon start\|stop\|status` | Background daemon management | Not implemented |

---

## Configuration

All tuneable parameters are in `config/config.exs`:

| Setting | Default | Purpose |
|---------|---------|---------|
| Embedding provider | `Cerno.Embedding.OpenAI` | Which embedding API to use |
| Embedding dimension | 1536 | Vector size |
| Semantic dedup threshold | 0.92 | Cosine similarity above which insights are merged |
| Cluster dedup threshold | 0.88 | Tighter threshold for intra-cluster dedup |
| Contradiction range | 0.5–0.85 | Similarity range that signals potential contradiction |
| Ranking weights | 35/25/20/15/5 | confidence / frequency / recency / quality / links |
| Decay half-life | 90 days | How fast knowledge decays without reinforcement |
| Decay threshold | 0.15 rank | Below this, status moves to `decaying` |
| Prune threshold | 0.10 rank | Below this, status moves to `pruned` |

---

## Tests

23 tests, 0 failures. All pure/unit tests — no database required.

| Test file | Tests | Coverage |
|-----------|-------|----------|
| `fragment_test.exs` | 4 | Deterministic IDs, hex format, path/content sensitivity |
| `parser_test.exs` | 10 | H2 splitting, line ranges, edge cases (no headings, empty), directory parsing, project derivation |
| `claude_test.exs` | 9 | Domain grouping, rank ordering, metadata toggle, empty input, output format |

---

## What Remains to Be Built

### Phase 2: Complete the Accumulation Pipeline

- [ ] Compute and persist embeddings on Insight records during ingestion
- [ ] Semantic dedup: query HNSW index for similarity > 0.92, merge instead of creating new
- [ ] File hash comparison in Accumulator to skip unchanged files
- [ ] Category, tag, and domain classification (heuristic or LLM-based)
- [ ] Contradiction detection during ingestion (similarity in 0.5–0.85 range)
- [ ] Accumulation run audit logging (`accumulation_runs` table)
- [ ] File watcher GenServer (populate `Cerno.Watcher.Supervisor`)

### Phase 3: Reconciliation

- [ ] Semantic clustering of active insights (DBSCAN or k-means on embeddings)
- [ ] Intra-cluster dedup at 0.88 threshold
- [ ] Cross-cluster contradiction scan (negation heuristic → embedding → LLM layered detection)
- [ ] Confidence adjustment rules (multi-project ↑, stale ↓, contradicted ↓)
- [ ] Promotion candidate flagging (confidence > 0.7, observations >= 3, age > 7d, no unresolved contradictions)

### Phase 4: Organisation & Long-Term

- [ ] Insight → Principle promotion (single insight direct, cluster LLM-synthesized)
- [ ] Principle dedup (content hash then embedding)
- [ ] Link detection and classification between principles
- [ ] Rank computation via `Principle.compute_rank/2`
- [ ] Pruning lifecycle: active → decaying (rank < 0.15, stale > 90d) → pruned (rank < 0.10, stale > 180d)
- [ ] Decay formula: `effective_lambda = lambda / (1 + log(frequency))`

### Phase 5: Resolution

- [ ] Parse target `CLAUDE.md`, compute embeddings for existing sections
- [ ] Retrieve relevant principles: hybrid scoring (50% semantic + 30% rank + 20% domain)
- [ ] Filter already-represented principles
- [ ] Contradiction detection between resolved principles and existing content
- [ ] `[CONFLICT]` markers for contradictions
- [ ] Resolution run audit logging (`resolution_runs` table)

### Phase 6: Polish & Extension

- [ ] Background daemon mode (`cerno daemon start/stop/status`)
- [ ] Phoenix REST API endpoints (project management, insights/principles CRUD, trigger operations)
- [ ] Embedding mock for tests (Mox-based `Cerno.Embedding.Mock`)
- [ ] Integration tests with Ecto sandbox (full accumulation pipeline)
- [ ] ChatGPT formatter
- [ ] Cursor formatter
- [ ] Local embedding provider (Nx/Bumblebee)
- [ ] Scheduled scan/reconciliation (periodic GenServer)
- [ ] `cerno calibrate` command for tuning dedup thresholds per domain
- [ ] Embedding model migration (re-embed all on model change, tracked via `embedding_model_config`)
