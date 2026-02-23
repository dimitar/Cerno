# Contributing to Cerno

Thanks for your interest in contributing to Cerno! This guide will help you get set up and understand our workflow.

## Prerequisites

- **Elixir 1.19+** and **Erlang/OTP 28+**
- **PostgreSQL 18+** with the [pgvector](https://github.com/pgvector/pgvector) extension installed
- Git

## Development Setup

```bash
# Clone and enter the repo
git clone https://github.com/dimitar/Cerno.git
cd Cerno

# Install dependencies
mix deps.get

# Create the database and run migrations
mix ecto.setup

# Verify everything works
mix compile --warnings-as-errors
mix test
```

### Database Notes

- Dev and test database passwords are configured in `config/dev.exs` and `config/test.exs`
- pgvector must be installed as a Postgres extension (`CREATE EXTENSION vector;` is handled by migrations)
- Tests use Ecto sandbox mode — no manual DB cleanup needed

## Project Structure

See [ARCHITECTURE.md](ARCHITECTURE.md) for the full module inventory. The key directories:

- `lib/cerno/atomic/` — Fragment parsing from context files
- `lib/cerno/short_term/` — Insight storage, clustering, confidence
- `lib/cerno/long_term/` — Principle promotion, linking, lifecycle
- `lib/cerno/process/` — GenServer pipeline (Accumulator, Reconciler, Organiser, Resolver)
- `lib/cerno/embedding/` — Pluggable embedding providers

## Making Changes

### Branch Naming

Use descriptive branch names: `fix/sandbox-race`, `feat/rest-api`, `docs/setup-guide`.

### Coding Conventions

- **Behaviours for extension points.** Implement callbacks, register, done.
- **GenServers for stateful processes.** One process per file.
- **PubSub for coordination.** Processes communicate via Phoenix.PubSub topics, not direct calls.
- **Ecto schemas with changesets.** All DB types use explicit changesets with validation.
- **Keep modules small.** One schema per file, one process per file.
- **Tests don't need Postgres** for pure logic. DB-backed tests use Ecto sandbox with `Cerno.Embedding.Mock`.

### Before Submitting

```bash
# Compile with no warnings
mix compile --warnings-as-errors

# Run the full test suite
mix test

# Format your code
mix format
```

All three must pass cleanly. CI will check these automatically.

## Pull Request Process

1. Fork the repo and create a branch from `main`
2. Make your changes, following the conventions above
3. Add or update tests for any new functionality
4. Ensure `mix test` passes and `mix compile --warnings-as-errors` is clean
5. Open a PR against `main` with a clear description of what and why

### PR Guidelines

- Keep PRs focused — one logical change per PR
- Reference any related issues (e.g., "Fixes #42")
- Add a brief test plan describing how to verify the change
- New behaviours or public APIs should include `@doc` and `@spec`

## Reporting Bugs

Use the [bug report template](https://github.com/dimitar/Cerno/issues/new?template=bug_report.yml) on GitHub Issues. Include:

- Steps to reproduce
- Expected vs actual behaviour
- Elixir/OTP/Postgres versions

## Requesting Features

Use the [feature request template](https://github.com/dimitar/Cerno/issues/new?template=feature_request.yml). Describe the problem you're trying to solve, not just the solution.

## License

By contributing, you agree that your contributions will be licensed under the [AGPL-3.0 License](LICENSE).
