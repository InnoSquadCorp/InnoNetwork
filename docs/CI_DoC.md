# CI DoC (Definition of Completion)

This document defines the minimum completion criteria (DoC) for pull requests in InnoNetwork.

## Scope

- Applies to all PRs targeting `main`.
- Applies to direct pushes to `main`.
- Mirrors local validation commands used in development.

## Required CI Checks

The `CI` workflow must pass all of the following:

1. `xcrun swift package resolve`
2. `xcrun swift build -Xswiftc -strict-concurrency=complete`
3. `xcrun swift test`
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
sudo xcode-select -s /Applications/Xcode_26.0.1.app
xcrun swift package resolve
xcrun swift build -Xswiftc -strict-concurrency=complete
xcrun swift test
rg -n "@unchecked Sendable" Sources
```
