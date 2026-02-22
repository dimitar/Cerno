# CLAUDE.md — Cerno

## Project Overview

Cerno is a layered, bidirectional memory system for AI agents. You are building the architecture and processes that govern how knowledge accumulates upward from atomic project files into long-term wisdom, and resolves back down into working memory when needed.

## Architecture

Three layers, each with distinct responsibilities:

1. **Atomic Memory** — Single-project context files (e.g., `CLAUDE.md`). The agent's working memory for a specific task. Most concrete and actionable.
2. **Short-Term Memory** — Aggregated knowledge across projects. Contains duplication and contradiction by design. A reconciliation process deduplicates, flags conflicts, clusters patterns, and formats output per agent type.
3. **Long-Term Memory** — Rationalised, ranked, linked knowledge distilled from short-term memory over time. Learnings, principles, and morals. An organisation process manages ranking, linking, pruning, and downward resolution.

## Core Mechanics

- **Accumulation (upward):** Atomic → Short-Term → Long-Term. Raw observations are gathered, sorted, and distilled.
- **Resolution (downward):** Long-Term → Short-Term → Atomic. Relevant knowledge is recalled, adapted, and injected into working memory for a task.
- **Reconciliation:** Deduplication, contradiction detection, pattern clustering at the short-term layer.
- **Organisation:** Ranking by confidence/frequency/recency, cross-domain linking, pruning at the long-term layer.

## Design Principles

- **Bidirectionality is the defining constraint.** Every data structure and process must support both upward accumulation and downward resolution.
- **Agent-agnostic storage, agent-specific output.** The memory store is universal; the rendering into working memory adapts per agent type (Claude, ChatGPT, etc.).
- **Knowledge has weight.** Observations are not equal — confidence, frequency, recency, and source quality all factor into ranking.
- **Contradiction is expected.** The system does not prevent contradictory knowledge from entering; it detects and resolves contradictions through explicit processes.
- **Pruning is as important as accumulation.** Outdated, superseded, or low-confidence knowledge must be actively removed.

## Conventions

- Keep code simple and modular. Each layer and process should be independently testable.
- Prefer explicit data models over implicit conventions.
- Document decisions in commit messages — this project is about knowledge management, so practice what it preaches.
- When in doubt about a design choice, favour the option that preserves bidirectionality.

## Current Phase

Early conceptual and architectural design. Focus on:
- Defining data models for knowledge units at each layer
- Designing the reconciliation and organisation processes
- Determining storage format and inter-layer interfaces
