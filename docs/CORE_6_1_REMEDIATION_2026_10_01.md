# Core 6.1 remediation execution

Status: implementation in progress; not Ready or published.

The maintainer approved the ten-step remediation plan on 2026-10-01 and
requested that changes extend PR #132. Merge, tags and publication are not
part of this authorization.

## Inputs and preservation

- PR #132 was OPEN/Draft at `79e1900ed283c129ab9523c7661c2f1a8e9cdc3c`.
- Base main was `9d8053d5f921ebf5c38cc2f816efe90c7db4a450`.
- Original checkout: `InnoNetwork-encoded-request`. Its 18 tracked dirty paths
  and two untracked groups were copied into an isolated worktree; all twenty
  preserved file hashes matched. Original files are not edited or staged.
- Existing corrections were selectively integrated from Sources/Tests through
  `7dccf4c`, including the final direct custom decoder compatibility correction.
  The historical review-document commit was not copied wholesale.
- Local toolchain is Xcode 27 / Swift 6.4. Prior diagnostic, remote, device and
  companion successes are not final-candidate evidence.

## Steps

1. Integration: focused tests passed (86 runtime + 4 macro test functions;
   parameterized cases are reported separately by Swift Testing).
2. Bounded scheduling primitives: passed 11 test functions, including extreme
   finite Double/Duration, relative-boundary and cancellation controls. Actual
   ContinuousClock and SuspendingClock 24h slices cancel without fatal timer
   conversion; the 24h value is a slice, not a total wait cap.
3. Core deadline/queue/rate paths: passed 57 test functions. Large budgets
   remain pending after a timer slice; queued cancellation releases scope state,
   server cooldown survives dispatch rechecks, and ordinary deadline/queue/rate
   controls pass. The initial new test had a catch-type compile error; its log
   is retained separately from the successful corrected fixture.
4. WebSocket/monitor/restored download paths: passed 86 test functions (55
   socket, 3 core monitor/defaults, 28 download). Large heartbeat/pong/reconnect
   and restored deadlines remain pending across slices and drain on cancellation.
   Non-finite restored deadlines use observable existing terminal-failure cleanup;
   destination files are not deleted and no persistence schema changes were made.
5. Retry jitter/delay arithmetic: pending.
6. Circuit backoff arithmetic: pending.
7. Macro helper coverage and unused binding: pending.
8. Documentation and local Periphery gate: pending.
9. Final frozen-source integration gates: pending.
10. Exact candidate evidence and remaining acceptance boundaries: pending.

Raw diagnostics and new execution logs are retained locally. Final counts,
source manifests and exit codes will be recorded after the last source change.
Dedicated services are unavailable; validation is limited to local fixtures.
The latest physical-device cold/warm run remains unverified while locked.
