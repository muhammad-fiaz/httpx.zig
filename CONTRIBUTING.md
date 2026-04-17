# Contributing to httpx.zig

Thank you for your interest in contributing to httpx.zig.

## Before You Start

- Read the project documentation: https://muhammad-fiaz.github.io/httpx.zig/
- Review the code of conduct in [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)
- Search existing issues and pull requests before opening a new one

## Development Setup

1. Install Zig 0.16.0 or newer.
2. Clone the repository.
3. From the repository root, run:

```bash
zig build
zig build test --summary all
```

## Build and Test Commands

- Build project:

```bash
zig build
```

- Run tests:

```bash
zig build test --summary all
```

- Build all supported targets:

```bash
zig build build-all-targets
```

- Run benchmarks:

```bash
zig build bench
```

- Run all runnable examples:

```bash
zig build run-all-examples
```

## Contribution Workflow

1. Fork the repository.
2. Create a feature branch from `main`.
3. Make focused changes with clear commit messages.
4. Add or update tests for behavior changes.
5. Update docs when public behavior changes.
6. Run build and test commands locally.
7. Open a pull request with a clear summary.

## Pull Request Guidelines

- Keep changes scoped to one concern where possible.
- Do not include unrelated refactors.
- Preserve existing public APIs unless the change requires it.
- For breaking changes, include migration notes in the PR description.

## Documentation Updates

If your change affects behavior, update the relevant files under `docs/` and API guides so examples stay correct.

## Versioning Notes

- `0.0.1` is the initial release.
- `0.0.2` includes compatibility fixes and maintenance updates.

For release history, see [CHANGELOG.md](CHANGELOG.md).
