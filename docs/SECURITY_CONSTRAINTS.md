# Security Constraints

This document describes the resource limits, validation rules, and safety measures built into Cerno. These are defense-in-depth measures — the primary security boundary is always OS-level permissions and network configuration.

## File Size Limits

Context files (CLAUDE.md, etc.) are capped at **1 MB** before reading.

| Location | Behavior |
|----------|----------|
| `Cerno.Atomic.Parser.ClaudeMd` | Returns `{:error, :file_too_large}` if the file exceeds 1 MB |
| `Cerno.Watcher.FileWatcher` | Skips oversized files during hash computation with a warning log |

**Why:** Prevents unbounded memory allocation from unexpectedly large files being read into memory.

## Path Validation

`Cerno.Security.validate_path/1` checks all user-supplied paths before processing:

- Rejects **symlinks** — prevents symlink-based path traversal
- Rejects **nonexistent paths** — catches typos and invalid input early
- Returns `{:ok, expanded_path}` or `{:error, reason}`

Applied in:
- CLI commands (`init`, `scan`, `resolve`)
- Resolver (non-dry-run mode)

**Why:** Defense-in-depth against path traversal attacks. OS permissions are the primary barrier, but application-level checks catch misuse early.

## Query Batch Limits

All unbounded `Repo.all()` queries have safety caps to prevent OOM on unexpectedly large datasets.

| Module | Limit | Notes |
|--------|-------|-------|
| `ShortTerm.Clusterer` | 5,000 insights | Sorted by `observation_count` DESC. Critical because clustering is O(n^2). |
| `ShortTerm.Confidence` | 10,000 insights | Logs warning when cap is hit |
| `LongTerm.Lifecycle` (decay) | 10,000 principles | Logs warning when cap is hit |
| `LongTerm.Lifecycle` (ranks) | 10,000 principles | Logs warning when cap is hit |
| `Process.Reconciler` (promotion) | 10,000 candidates | Prevents unbounded promotion query |

**Why:** Prevents out-of-memory conditions if the database grows beyond expected size. All limits log warnings when hit so operators can tune them.

## TaskSupervisor Limits

`Cerno.Process.TaskSupervisor` has `max_children: 20`, preventing runaway task spawning if many files change simultaneously.

## Accumulation Cooldown

The Accumulator enforces a **30-second per-path cooldown** after completing accumulation. If a path was just processed, re-accumulation requests are silently skipped. This works alongside the existing `processing` MapSet that prevents concurrent processing of the same path.

## ETS Cache Eviction

The embedding cache (`Cerno.Embedding.Cache`) evicts the oldest 10% of entries when exceeding 10,000 entries. Eviction uses `:ets.select/2` with a match spec to avoid loading full embedding vectors into memory during cleanup.

## LLM CLI Execution

The Claude CLI integration (`Cerno.LLM.ClaudeCli`) uses `System.cmd/3` instead of `:os.cmd/1`. This bypasses the shell entirely — prompt text is passed via the `:input` option (stdin), eliminating shell injection risk. No temporary files are created.

## API Error Sanitization

The OpenAI embedding provider (`Cerno.Embedding.OpenAI`) strips API response bodies to only include the `"error"` field, preventing accidental logging of request/response bodies that could contain sensitive data.

## Database Credentials

Dev/test database passwords support environment variable override (`CERNO_DB_PASSWORD`). The defaults are development-only values. Production credentials are configured via `runtime.exs` using environment variables exclusively.
