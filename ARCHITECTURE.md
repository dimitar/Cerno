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

The working memory of a single project. Raw text extracted from agent context files (`CLAUDE.md`, `.cursorrules`, etc.).

**Key type: `Fragment`** — an in-memory struct (not persisted) representing one section of a context file.

```
Fragment
├── id            deterministic SHA-256(source_path + content)
├── content       raw text of the section
├── source_path   absolute path to the source file
├── source_project  project name derived from directory
├── section_heading  section heading text (nil for preamble)
├── line_range    {start_line, end_line}
├── file_hash     SHA-256 of the entire file
└── extracted_at  UTC timestamp
```

**Parser architecture:** Pluggable via `Cerno.Atomic.Parser` behaviour. Each agent's context file format gets its own parser. The dispatcher routes files to the correct parser based on filename.

```
Cerno.Atomic.Parser (behaviour + dispatcher)
├── parse/1              route file to correct parser by filename
├── parse_directory/1    scan dir for all recognised file patterns
├── find_parser/1        look up parser module for a filename
├── registered_patterns/0  list all file patterns from registered parsers
├── file_pattern/0       callback — glob pattern this parser handles
└── hash_file/1          SHA-256 utility

Cerno.Atomic.Parser.ClaudeMd     CLAUDE.md → Fragments (split by H2 headings)
(future) Parser.CursorRules      .cursorrules → Fragments
(future) Parser.WindsurfRules    .windsurfrules → Fragments
```

**Modules:**

| Module | Purpose | Status |
|--------|---------|--------|
| `Cerno.Atomic.Fragment` | Struct definition, deterministic ID generation | Complete |
| `Cerno.Atomic.Parser` | Behaviour definition, dispatcher (routes by filename), directory scanning | Complete |
| `Cerno.Atomic.Parser.ClaudeMd` | `CLAUDE.md` parser — splits on H2 headings, tracks line ranges | Complete |

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

**Query methods on `Insight`:**
- `find_similar/2` — pgvector cosine similarity search (`1 - (a <=> b)`), configurable threshold/limit/status filter
- `find_contradictions/2` — finds insights in the contradiction similarity range (default 0.5–0.85)
- `hash_content/1` — SHA-256 for exact dedup

**Supporting types:**

| Type | Table | Purpose |
|------|-------|---------|
| `InsightSource` | `insight_sources` | Links insight → original file, project, line range, fragment ID. Unique on `fragment_id` to prevent reprocessing. |
| `Contradiction` | `contradictions` | Pair of conflicting insights with type (direct/partial/contextual), resolution lifecycle (unresolved → resolved/dismissed), and similarity score. Unique pair constraint via `LEAST/GREATEST`. |
| `Cluster` | `clusters` | Semantic grouping with centroid embedding and coherence score. Many-to-many with insights via `cluster_insights`. |
| `Classifier` | — | Heuristic keyword-based classifier. Determines category, tags, and domain from fragment content without LLM calls. |

**Modules:**

| Module | Purpose | Status |
|--------|---------|--------|
| `Cerno.ShortTerm.Insight` | Ecto schema, changeset, `hash_content/1`, `find_similar/2`, `find_contradictions/2` | Complete |
| `Cerno.ShortTerm.InsightSource` | Ecto schema, changeset | Complete |
| `Cerno.ShortTerm.Contradiction` | Ecto schema, changeset | Complete |
| `Cerno.ShortTerm.Cluster` | Ecto schema, changeset | Complete |
| `Cerno.ShortTerm.Classifier` | Heuristic category/tag/domain classification | Complete |
| `Cerno.ShortTerm.Clusterer` | Connected-component clustering, intra-cluster dedup, cross-cluster contradiction scan, `cosine_similarity/2` | Complete |
| `Cerno.ShortTerm.Confidence` | Multi-project boost, stale decay, contradiction penalty, observation floor, `adjust_all/0` | Complete |

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
| `Cerno.LongTerm.Promoter` | Insight-to-principle promotion with exact + semantic dedup, category mapping, `promote_eligible/0` | Complete |
| `Cerno.LongTerm.Linker` | Typed link detection between principles (reinforces, related, contradicts, generalizes/specializes), `detect_links/0` | Complete |
| `Cerno.LongTerm.Lifecycle` | Exponential recency decay, rank recomputation with link counts, pruning lifecycle, `run/0` | Complete |

---

## Core Processes

Four GenServers form the processing pipeline, connected via Phoenix PubSub events:

```
file:changed ──▶ Accumulator ──accumulation:complete──▶ Reconciler ──reconciliation:complete──▶ Organiser
                                                                                                    │
resolution:requested ──▶ Resolver ◀─────────────────────────────────────────────────────────────────┘
```

### Accumulator — `Cerno.Process.Accumulator`

Drives the upward flow from files to short-term memory. Full pipeline implemented.

**Current implementation:**
1. Receive path (via PubSub `file:changed`, CLI `scan`, or `scan_all`)
2. Skip if already processing that path (MapSet-based lock)
3. Compare file hash against `WatchedProject.file_hash` — skip unchanged files
4. Parse via pluggable `Cerno.Atomic.Parser` → Fragments
5. For each fragment:
   - **Exact dedup:** `content_hash` match → increment `observation_count`, update `last_seen_at`, add `InsightSource`
   - **Get embedding** via `Cerno.Embedding.Pool` (graceful fallback if embedding service is down)
   - **Semantic dedup:** cosine similarity > 0.92 → merge into existing insight
   - **New insight:** create with embedding, classify category/tags/domain via `Classifier`
   - **Contradiction check:** query similarity range 0.5–0.85, create `Contradiction` records
6. Update `WatchedProject.file_hash` after scan
7. Log results to `AccumulationRun` (fragments found, insights created/updated, errors)
8. Broadcast `accumulation:complete` on PubSub

### Reconciler — `Cerno.Process.Reconciler`

Runs reconciliation within the short-term layer. Auto-triggered after accumulation completes.

**Current implementation:**
1. Cluster all active insights via `Clusterer.cluster_insights/0` — builds embedding similarity graph at 0.88 threshold, finds connected components via BFS, computes centroid and coherence per cluster
2. Intra-cluster dedup via `Clusterer.dedup_within_clusters/1` — within each cluster, winner (highest observation count) absorbs losers with similarity >= 0.88, losers marked `:superseded`
3. Re-cluster and persist via `Clusterer.persist_clusters/1` — full rebuild (delete old, insert new)
4. Cross-cluster contradiction scan via `Clusterer.scan_cross_cluster_contradictions/1` — compare centroids, if in 0.5–0.85 range, check member pairs with negation heuristic ("always"↔"never", "use"↔"avoid", "should"↔"should not", etc.), creates `Contradiction` records (`:direct` for negation match, `:partial` for embedding-only)
5. Confidence adjustment via `Confidence.adjust_all/0` — multi-project boost (+0.05 per additional project), stale decay (×0.9 after 90 days), contradiction penalty (×0.8), observation floor (log scale, capped at 0.6), clamped to [0.0, 1.0]
6. Log promotion candidates via `promotion_candidates/0` — confidence > 0.7, observations >= 3, age > 7 days, no unresolved contradictions, not already promoted (configurable via `:cerno, :promotion`)

### Organiser — `Cerno.Process.Organiser`

Promotes insights to principles (short-term → long-term). Auto-triggered after reconciliation completes.

**Current implementation:**
1. Promote eligible insights via `Promoter.promote_eligible/0` — queries insights meeting promotion criteria, deduplicates against existing principles (exact content_hash match, then semantic similarity >= 0.92), creates Principle + Derivation records. Category mapping: convention→heuristic, technique→learning, warning→anti_pattern, etc.
2. Detect links via `Linker.detect_links/0` — for each active principle, finds others with similarity > 0.5. Classifies: >0.85 → reinforces, 0.7–0.85 + same domain → related, 0.5–0.7 + negation → contradicts, shared tags + different domains → generalizes/specializes
3. Lifecycle via `Lifecycle.run/0` — exponential recency decay with frequency-adjusted half-life (`2^(-days / (half_life / (1 + log(freq))))`), rank recomputation via `Principle.compute_rank/2` with current link counts, pruning (rank < 0.15 + stale 90d → decaying, rank < 0.10 + stale 180d → pruned)

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

## File Watcher — `Cerno.Watcher.FileWatcher`

Polling-based GenServer that monitors project directories for context file changes. Started dynamically under `Cerno.Watcher.Supervisor` (DynamicSupervisor), registered via `Cerno.Watcher.Registry`.

**Behaviour:**
1. On start: scan project path for all registered file patterns, hash each file (baseline)
2. On poll (default 30s): re-hash files, compare against baseline
3. On change detected: broadcast `{:file_changed, path}` on `file:changed` PubSub topic
4. Accumulator subscribes to `file:changed` and triggers accumulation

**API:**
- `start_watching/2` — start watching a project path
- `stop_watching/1` — stop watching
- `list_watched/0` — list all watched paths

---

## Embedding Subsystem — `Cerno.Embedding`

Pluggable embedding system with batching and caching.

```
Cerno.Embedding (behaviour)
├── embed/1          single text → vector
├── embed_batch/1    multiple texts → vectors
└── dimension/0      vector dimension (1536)

Cerno.Embedding.OpenAI    OpenAI API provider (text-embedding-3-small)
Cerno.Embedding.Mock       Deterministic mock for tests (hash-based vectors)
Cerno.Embedding.Pool       GenServer that batches requests (20 items or 500ms flush)
Cerno.Embedding.Cache      ETS-backed LRU cache (10,000 entries, SHA-256 keys)
```

The behaviour is implemented by `Cerno.Embedding.OpenAI`. Additional providers (Voyage, Nx/Bumblebee for local inference) can be added by implementing the three callbacks.

The test environment uses `Cerno.Embedding.Mock` which generates deterministic embeddings by cycling SHA-256 hash bytes as floats.

**Postgrex types:** Custom `Cerno.PostgrexTypes` module registers `Pgvector.Extensions.Vector` for the `vector` column type.

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

## Audit Logging

### AccumulationRun — `Cerno.AccumulationRun`

Tracks each accumulation scan. Fields: project_path, status (running/completed/failed), fragments_found, insights_created, insights_updated, errors[], started_at, completed_at.

Convenience functions: `start/1`, `complete/2`, `fail/2`.

---

## OTP Supervision Tree

```
Cerno.Application (one_for_one)
├── Cerno.Repo                              Ecto PostgreSQL pool (with Cerno.PostgrexTypes)
├── {Phoenix.PubSub, name: Cerno.PubSub}    Event bus for process coordination
├── Cerno.Embedding.Pool                     Batched embedding requests
├── Cerno.Embedding.Cache                    ETS embedding cache
├── Cerno.Watcher.Registry                   Registry for FileWatcher processes
├── DynamicSupervisor (Cerno.Watcher.Supervisor)
│     └── Cerno.Watcher.FileWatcher          Per-project file polling (30s default)
├── Task.Supervisor (Cerno.Process.TaskSupervisor)  Async work within processes
├── Cerno.Process.Accumulator                Files → Short-Term (full pipeline)
├── Cerno.Process.Reconciler                 Short-Term reconciliation (full pipeline)
├── Cerno.Process.Organiser                  Short-Term → Long-Term (full pipeline)
└── Cerno.Process.Resolver                   Long-Term → Files (partial)
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
| `cerno reconcile` | Trigger reconciliation | Working |
| `cerno organise` | Trigger organisation | Working |
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
| Promotion min confidence | 0.7 | Minimum confidence for promotion candidates |
| Promotion min observations | 3 | Minimum observation count for promotion |
| Promotion min age | 7 days | Minimum age before an insight can be promoted |
| Resolution semantic weight | 0.5 | Semantic similarity weight in hybrid scoring |
| Resolution rank weight | 0.3 | Rank weight in hybrid scoring |
| Resolution domain weight | 0.2 | Domain match weight in hybrid scoring |
| Resolution min hybrid score | 0.3 | Minimum hybrid score for inclusion |
| Resolution max principles | 20 | Maximum principles to resolve into a file |
| Already-represented threshold | 0.85 | Similarity above which a principle is filtered out |

---

## Tests

135 tests, 0 failures. Mix of pure/unit tests and database-backed tests with Ecto sandbox.

| Test file | Tests | Coverage |
|-----------|-------|----------|
| `fragment_test.exs` | 4 | Deterministic IDs, hex format, path/content sensitivity |
| `parser_test.exs` | 18 | Dispatcher routing, `find_parser`, `parse_directory` across subdirs, ClaudeMd H2 splitting, line ranges, edge cases, project derivation |
| `claude_test.exs` | 9 | Domain grouping, rank ordering, metadata toggle, empty input, output format |
| `classifier_test.exs` | 16 | Category detection (warning/convention/technique/fact/default), tag detection (multi-tag, limit), domain detection, fragment map input, classification structure |
| `insight_test.exs` | 11 | Changeset validation, hash_content consistency, CRUD with Ecto sandbox, find_similar with pgvector, unique content_hash constraint |
| `accumulation_run_test.exs` | 6 | Start/complete/fail lifecycle, error accumulation, changeset validation |
| `file_watcher_test.exs` | 10 | Start/stop watching, Registry integration, duplicate rejection, change detection via PubSub, no-broadcast on unchanged |
| `clusterer_test.exs` | 19 | Cosine similarity math, connected components (BFS), cluster_insights with DB, persist/rebuild, intra-cluster dedup (merge + supersede), cross-cluster contradiction scan |
| `confidence_test.exs` | 15 | Multi-project boost, stale decay, contradiction penalty, observation floor, clamping, adjust_all lifecycle, distinct_project_count, has_unresolved_contradictions |
| `reconciler_test.exs` | 6 | Promotion candidates (criteria filtering, exclusions), full pipeline integration (PubSub broadcast, cluster creation) |
| `promoter_test.exs` | 7 | Exact dedup, semantic dedup, category mapping, promote_eligible pipeline, re-promotion skip |
| `linker_test.exs` | 5 | Link detection by similarity, classification (reinforces, related, contradicts), direction normalization, no duplicate links |
| `lifecycle_test.exs` | 7 | Decay (recent vs stale), rank recomputation (with link count), pruning (rank + age thresholds), full run/0 pipeline |
| `organiser_test.exs` | 2 | Full pipeline (promote → link → lifecycle), empty pipeline (no insights) |

---

## What Remains to Be Built

### ~~Phase 3: Reconciliation~~ — Complete

- [x] Connected-component clustering via BFS on embedding similarity graph (threshold 0.88)
- [x] Intra-cluster dedup — winner absorbs loser's observation_count, max last_seen_at, loser → `:superseded`
- [x] Cross-cluster contradiction scan — centroid comparison + negation heuristic + `Contradiction` record creation
- [x] Confidence adjustment — multi-project boost, stale decay, contradiction penalty, observation floor
- [x] Promotion candidate flagging (configurable via `:cerno, :promotion`)
- [x] Full Reconciler GenServer wiring with PubSub integration

### ~~Phase 4: Organisation~~ — Complete

- [x] Insight → Principle promotion with exact + semantic dedup (`Promoter.promote_eligible/0`)
- [x] Category mapping: convention→heuristic, technique→learning, warning→anti_pattern, etc.
- [x] Link detection and classification between principles (`Linker.detect_links/0`)
- [x] Link types: reinforces (>0.85), related (0.7–0.85 + same domain), contradicts (0.5–0.7 + negation), generalizes/specializes (shared tags + different domains)
- [x] Exponential recency decay with frequency-adjusted half-life (`Lifecycle.apply_decay/0`)
- [x] Rank recomputation via `Principle.compute_rank/2` with link counts (`Lifecycle.recompute_ranks/0`)
- [x] Pruning lifecycle: active → decaying (rank < 0.15, stale > 90d) → pruned (rank < 0.10, stale > 180d) (`Lifecycle.apply_pruning/0`)
- [x] Full Organiser GenServer wiring with PubSub integration

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
- [ ] Integration tests with Ecto sandbox (full accumulation pipeline end-to-end)
- [ ] ChatGPT formatter
- [ ] Cursor formatter (`Parser.CursorRules` + `Formatter.Cursor`)
- [ ] Windsurf parser (`Parser.WindsurfRules`)
- [ ] Local embedding provider (Nx/Bumblebee)
- [ ] Scheduled scan/reconciliation (periodic GenServer)
- [ ] `cerno calibrate` command for tuning dedup thresholds per domain
- [ ] Embedding model migration (re-embed all on model change, tracked via `embedding_model_config`)
