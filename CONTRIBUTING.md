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

`API_STABILITY.md` is the public ledger. When a symbol is added, removed,
promoted, or deprecated, update the ledger in the same change so reviewers can
see whether the proposal is a patch-safe fix, a minor-version addition, or a
future-major RFC.

The generated symbol allowlists under `Scripts/symbols/` are review aids, not
busywork. They make public surface changes explicit in pull requests and catch
accidental exports from helper targets. If a symbol is intentionally public,
add it to the matching allowlist and explain the contract in docs or symbol
comments.

Periphery is used to find dead private/package code before it becomes part of
the maintenance surface. Do not silence Periphery by default. Keep code only
when it is dynamically referenced, a fixture, or a deliberate public contract,
and leave the reason near the allowlist or in the PR description.

## Maintainer Escalation

InnoNetwork is maintained by a single primary maintainer. Response is
best-effort and there is no SLA — see [SUPPORT.md](SUPPORT.md) for the
triage priority order.

If you need an urgent path:

- **Security vulnerabilities** — do **not** open a public issue. Follow the
  private disclosure flow in [SECURITY.md](SECURITY.md). Tag the report as
  `severity: critical` if exploitation is trivial; the maintainer prioritizes
  these above all other work.
- **Production regression on a `Stable` ledger entry** — open a GitHub issue
  prefixed with `[regression]` and include (a) the affected version range,
  (b) a minimal reproducer, and (c) the previous-version behaviour. These
  are triaged immediately.
- **Critical CVE in a transitive dependency** — the core request product keeps
  its dependency budget intentionally small, but optional products may depend
  on companion packages such as `swift-crypto`. Report via the same private
  security flow if you spot one in runtime or development tooling
  (`swift-crypto`, `swift-syntax`, action SHAs).

If the primary maintainer is unreachable for more than two weeks on a
critical-severity report, contact `InnoSquadCorp` org owners through the
GitHub org page so a co-maintainer can be temporarily granted access. The
org owner list is the documented fall-back; this prevents critical patches
from being blocked indefinitely on a single keyholder.

## Commit / PR Checklist

- Tests pass locally.
- Docs contract sync passes.
- Consumer smoke build still succeeds.
- Changelog and release notes are updated when behavior changes.
