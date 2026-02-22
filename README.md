# Cerno

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

### Layer 1: Atomic Memory

The working memory of a single project or task. Files like `CLAUDE.md` that contain context-specific rules, principles, and conventions. This is the **attention layer** — what the agent focuses on right now.

- Scoped to a single project or task
- Directly consumed by the agent during execution
- The most concrete, actionable layer

### Layer 2: Short-Term Memory

A collective grouping across atomic memory files. This layer aggregates knowledge from multiple projects and sessions. It is expected to contain duplication, contradiction, and varying levels of confidence.

A **reconciliation process** runs at this layer which:

- Deduplicates overlapping knowledge
- Flags contradictions for resolution
- Clusters related observations into emerging patterns
- Optimises output format per agent type (e.g., Claude vs ChatGPT vs other LLMs)

### Layer 3: Long-Term Memory

The fully rationalised collection of short-term memories accumulated over time. This is where observations crystallise into:

- **Learnings** — verified patterns and techniques
- **Principles** — general rules derived from repeated experience
- **Morals** — hard-won lessons from failures and edge cases

An **organisation process** at this layer:

- Ranks knowledge by confidence, frequency, and recency
- Links related concepts across domains
- Prunes outdated or superseded knowledge
- Resolves accumulated wisdom back downward into short-term memory and atomic files when a relevant task or project is being worked on

## Bidirectional Flow

The defining mechanic of Cerno is that knowledge flows in both directions:

```
Atomic Memory ──accumulate──▶ Short-Term Memory ──distil──▶ Long-Term Memory
     ◀──resolve───                    ◀──recall──
```

**Upward (accumulation):** Raw observations from project work are gathered, sorted, and distilled into higher-order knowledge.

**Downward (resolution):** When a new task begins, relevant long-term knowledge is recalled, adapted to context, and resolved into the agent's working memory.

## Agent-Specific Optimisation

The short-term memory layer is format-aware. Different AI agents consume context differently — what works as a `CLAUDE.md` for Claude may not be optimal for ChatGPT's system prompt or another agent's context window. Cerno adapts its output format per target agent.

## Status

Early conceptual phase. Architecture and processes under active design.
