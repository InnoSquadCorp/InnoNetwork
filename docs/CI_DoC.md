# CI DoC (Definition of Completion)

This document defines the minimum completion criteria (DoC) for pull requests in InnoNetwork.

## Scope

- Applies to all PRs targeting `main`.
- Applies to direct pushes to `main`.
- Mirrors local validation commands used in development.

## Required CI Checks

The `CI` workflow must pass all of the following:

1. `swift package resolve`
2. `swift build -Xswiftc -strict-concurrency=complete`
3. `swift test`
4. `rg -n "@unchecked Sendable" Sources` returns no matches

## Pass/Fail Policy

- A PR is considered complete only when all CI checks are green.
- If any check fails, the PR is not merge-ready.
- Concurrency regressions and `@unchecked Sendable` additions in production sources are blocking failures.

## Integration Tests Policy

- Network-dependent tests should remain opt-in via `INNONETWORK_RUN_INTEGRATION_TESTS=1`.
- Default CI runs deterministic unit tests only.

## Local Reproduction

Run the same commands locally:

```bash
swift package resolve
swift build -Xswiftc -strict-concurrency=complete
swift test
rg -n "@unchecked Sendable" Sources
```
