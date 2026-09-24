# 6.0 Release Hardening and Operational Acceptance

Scope baseline: main `7b52580430881e7b222f589aee7a30e409ed17da`.
This follow-up keeps the approved 6.0 feature scope and API classifications.
It is not a release-ready declaration and does not publish a tag.

## Implemented checks

| Area | Change and passing control |
| --- | --- |
| Cache contract | RFC matrix now states current Age is returned on reuse. Existing hit, stale recovery, and 304 tests exercise that behavior; docs-contract sync rejects the obsolete unsupported claim. |
| VCR privacy | Recording and mismatch errors remove URL user-info and fragments. Transport receives the original URL. Tests preserve path encoding, IPv6/port/query identity, custom query policy, legacy replay order, and explicit disk migration without rewriting the source. |
| Upload ID history | Contiguous and sparse stateless-session workloads preserve exact IDs and suppress a late callback. Manager shutdown and channel finish release history; finished channels reject subsequent events. |
| Resumable process recovery | A worker exits after durable chunk acceptance before acknowledgement, or after finalization before checkpoint cleanup. A fresh worker reopens the real file checkpoint store, probes the durable fixture, sends no duplicate bytes, uses fresh credentials, reuses the session, and removes the checkpoint after success. |

The VCR privacy tests fail against the baseline implementation and pass after
the change. The channel-finish assertions likewise fail before its cleanup fix.
The recovery adapter is a deterministic file-backed stand-in, not a production
HTTP backend. Abrupt fixture exit is deliberate and affects only that worker.

## Fresh local evidence — 2026-09-24

The validated runtime, test, fixture, manifest, and workflow files are captured
by `1330ace10f6c6bd56f675f36ff2cdcc183f0cb2b` (including VCR change `558a10f`).
The subsequent documentation commit records these results without changing
those files.

- Xcode 27.0 (27A266a), Apple Swift 6.4, macOS arm64.
- Full serial suite: 1,837 registered tests, 1,833 passed and 4 explicitly
  skipped external-service tests; command exit 0.
- Upload repetition: 10,000 contiguous and 10,000 sparse tasks, plus 10,000
  overflow events for each ID pattern. Four argument cases passed; late
  callbacks did not recreate tasks and both histories cleared on termination.
  Test execution was 2.845 seconds, not a long-duration production soak.
- Two fresh-process recoveries passed after rebuilding the fixture.
- Public API contract: 1,614 declarations unchanged (306 Stable,
  1,275 Provisionally Stable, 33 SPI); docs-contract sync passed.
- The independent `Examples/TestSupportSmoke` consumer built and ran.
- Swift formatting, shell syntax, YAML parsing, release-state fixtures,
  documentation assertion helpers, preflight wiring fixtures, and
  publication-safety workflow fixtures passed.

Local logs use the prefix `/tmp/innonetwork6-hardening-`, including
`full-test.log`, `upload-soak.log`, `process-recovery-final.log`, `docs.log`,
and `format.log`. These temporary logs can be removed by environment cleanup;
the committed commands and fixtures are the reproducible record.
Final-candidate remote CI and device/backend acceptance were not run.

## Reproduce

Run from the repository root:

```sh
xcrun swift test --jobs 2 --no-parallel
bash Scripts/check_docs_contract_sync.sh
bash Scripts/test_resumable_process_recovery.sh
bash Scripts/tests/test_run_local_release_preflight.sh
bash Scripts/format.sh --lint
INNO_UPLOAD_SOAK_ITERATIONS=10000 xcrun swift test --skip-build --no-parallel --filter UploadIdentifierRetentionTests
```

The process fixture runs in CI, release validation, and the local preflight's
documentation-smoke gate. It leaves a small credential-free evidence directory
containing checkpoints/backend state and the interrupted worker's private
snapshot. It never terminates a compiler, build, test runner, or unrelated app.

The long-run test defaults to 1,000 operations per pattern; explicit runs allow
1–100,000. A run with N sequential IDs needs one range; N isolated IDs need N
ranges until shutdown. These are exact state-size assertions, not a constant
heap bound. Whole-command RSS includes SwiftPM and test-runner overhead and
must not be reported as the ID container's allocation size. A finite
`maximumRetainedTerminalTasks` is not a ceiling on callback-suppression history.

## External acceptance matrix — still required for the relevant adoption

| Boundary | Procedure and acceptance evidence | Current limitation |
| --- | --- | --- |
| iOS background daemon | On a dedicated physical iPhone, suspend/resume an upload/download; exercise system termination and relaunch, user-paused restoration, and exactly-once completion. Record device/OS/app/library revisions and server byte counts. Test explicit user force-quit separately because its OS behavior differs. | The listed physical iPhone is unavailable; simulator and macOS tests do not close this row. |
| Protected storage | While the physical device is locked, exercise configured protection classes, delayed callbacks and relaunch. Verify unreadable files fail without corrupting checkpoints and become usable when permitted. | No physical-device run or power-loss test was performed. |
| Real resumable service | With a dedicated test account and disposable object, interrupt before/after each acknowledgement, expire credentials, change source identity, and retry finalization. Verify server offsets/checksum and no duplicate creation or credential persistence. | The local durable adapter proves engine recovery, not a specific backend's contract. Test service/account has not been supplied. |
| Real quota/identity provider | Replay a documented quota/burst pattern, cancellation and 429/Retry-After behavior; exercise realm-separated credential refresh. Record rate/latency and server observations without credentials. | No service-specific quota model or IdP account has been supplied. Keep advanced APIs Provisionally Stable. |
| Long-lived streaming/export | Use a bounded-duration load and a slow/failing exporter; capture memory trend, drops, completion and cancellation behavior, with a named consumer adapter. | Short deterministic regressions and the upload workload are not an overnight stream/export soak or real exporter certification. |
| Publication | Re-run final-SHA remote checks, close consumer gates, then change Draft to Ready and follow tagged companion-dependency validation order. | This local hardening invalidates using the earlier main CI as final-candidate proof. No tag is published by these checks. |

Do not store account secrets or real payloads in fixtures. Obtain the dedicated
environment before running tests that create server resources or alter app
lifecycle. Feature-scoped managers should shut down once work is finished;
shutdown cancels active transfers, so do not rotate during background work to
reclaim history.

## Deliberately separate feature proposals

Request freshness directives (such as request `no-cache` and `min-fresh`) and
preview-generator path/auth/schema expansion remain separate adoption-driven
proposals. They are not silently added to this hardening change. A concrete
consumer requirement, compatibility decision, negative tests, and API ledger
update are required before adding them to a release scope.
