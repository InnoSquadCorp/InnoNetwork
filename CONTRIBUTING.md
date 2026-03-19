# Contributing to InnoNetwork

Thanks for contributing to InnoNetwork.

## Before You Start

- Read [API Stability](API_STABILITY.md) before proposing public API changes.
- Read [Support](SUPPORT.md) to understand the maintainer response model.
- For security issues, do not open a public issue. Follow [SECURITY.md](SECURITY.md).

## Development Setup

```bash
swift test
bash Scripts/check_docs_contract_sync.sh
swift build --target InnoNetworkDocSmoke
swift build --target InnoNetworkBenchmarks
```

For benchmark validation:

```bash
swift run InnoNetworkBenchmarks --quick --json-path /tmp/innonetwork-bench.json
```

## Pull Request Expectations

- Keep public API changes narrow and justified.
- Update documentation when behavior or contracts change.
- Add or update tests for any user-visible behavior.
- Keep examples aligned with `safeDefaults` unless the example is explicitly about advanced tuning.
- Do not introduce `@unchecked Sendable` in production sources.

## Public API Policy

- `Stable` API changes require migration notes and changelog updates.
- `Provisionally Stable` APIs can evolve more quickly, but still require documentation updates.
- `Internal/Operational` items should not be relied on by downstream consumers.

## Commit / PR Checklist

- Tests pass locally.
- Docs contract sync passes.
- Consumer smoke build still succeeds.
- Changelog and release notes are updated when behavior changes.
