# Android / Web 1.0.0 readiness record

Assessment date: 2026-10-18 KST. Baseline: `ac0363674c974b8fd0423f29d17ea7791d28dbcb`
plus the cross-platform working-tree changes. This is an installable local 1.0.0
candidate, not evidence of public Maven Central/npm publication. The root Swift
manifest, lockfile, sources, and tests remain equal to `origin/main`.

## Scope and exit criteria

The review covers Android's native session, typed client, KSP, and optional JSON
adapter; Web's native Fetch session/client; public API/ABI and package contents;
independent consumers; React lifecycle; and CI/release checks. Exit criteria are
reproduced defects fixed with passing controls, portable gates passing against
unchanged source, real installed-artifact execution, and explicit qualifications
for platforms or release operations not verified locally.

Swift runtime changes, full Swift feature parity, app-owned auth/refresh/replay,
background restoration, WebSockets, persistence, and React Native are excluded.
Native OkHttp/Fetch configuration remains the application boundary for TLS,
timeouts, cache, cookies, credentials, interceptors, and observability.

## Confirmed corrections in this pass

- Buffered Android callback exceptions now settle the suspended caller. Bodies
  close before result delivery, cancelled calls do not read late responses, and
  already cancelled coroutines do not create native calls.
- KSP emits collision-safe names/imports, handles default and keyword packages,
  diagnoses inaccessible properties, preserves trailing slashes, and accepts
  native `RequestBody` subtypes. Literal/runtime dot-segment guards remain.
- Web ceilings use decoded bytes rather than compressed wire length. Bodyless
  HTTP responses work even when an engine exposes an empty non-null stream.
  A size failure does not wait indefinitely for a stream's cancellation hook.
- Pre-aborted/late-resolved requests and async decoder cancellation retain the
  cancellation contract; obsolete decoded results are not delivered.
- Node-only consumers no longer require DOM-only type names. Real tarballs
  include resolvable source maps. Maven binaries, sources, and docs embed the
  current license, checked against the repository license.
- Wrapper integrity is checked before execution. Test-count gates exclude
  skipped tests and reject failed/error results. The independent Android
  consumer builds an actual API-21-targeted R8-minified APK.

The preceding pass's redaction, origin-scoped default-header redirect guard,
bounded buffering, immutable buffered data, and native request escape hatches
are retained and included in the regression gates.

## Validation matrix

| Boundary | Evidence | Result / limit |
| --- | --- | --- |
| Normal HTTP and typed decoding | Android 17 transport, 4 client, 3 serialization tests; Web 29 tests | Fresh local checks |
| I/O, status, decoding failure | Native MockWebServer and Fetch fixtures; custom callback read/close failures | Caller settles; HTTP failures stay values until explicitly rejected |
| Cancellation and ownership | Awaiting headers, body buffering, pre-cancel, late response, stream handoff race, async decoder abort | Fresh controlled and native checks |
| Concurrency and React replacement | 8 concurrent Android requests; React StrictMode, unmount, input replacement, invalid payload | Android runtime and 5 React tests |
| Resource limits | Declared/chunked bodies, gzip, one-byte chunks, empty HEAD stream, never-settling cleanup | Bounded buffered path; streaming remains caller-owned |
| KSP authoring | 5 parser tests; 8 Maven-consumer tests; deterministic negative diagnostics | Packages/names, native body subtypes, trailing slash, dot segments covered |
| Observability and security | Native EventListener/Fetch injection, URL redaction, separate redirect destination with zero requests, dependency verification | No custom TLS stack or exporter claim |
| Compatibility and artifacts | JVM signatures, Kotlin ABI, explicit API, lint, Maven structure/license/checksums, packed npm declarations/runtime | Fresh local checks; no registry signature/provenance claim |
| Android packaging/runtime | API-21-targeted D8/R8 APK; actual API 26 emulator execution | KSP, JSON, concurrent requests, gzip, limit, streaming, cancellation passed; API 21-25 device execution unverified |
| TypeScript/runtime consumers | TypeScript 7.0.2, DOM and Node-only projects; installed tarball on Node 22.0.0; maintainer Node 24/26 | Exact Node receipt is recorded in a generated release bundle |
| Native browser engines | Playwright 1.64.1: Chromium 156 and WebKit 27.2 on macOS 27.0.1 | Passed; this is WebKit engine evidence, not iOS Safari device evidence |
| Firefox | Launch fails with `Could not find profile folder` before page/library code, including a fresh persistent-profile control | Local environment qualification remains; required Linux CI lane retained |
| Retry/restoration | No library retry or restoration layer in Android/Web 1.0 | Intentionally outside this release; native policy remains explicit |
| Remote CI / release | Static Actionlint/ShellCheck and local gates | Remote execution, registry ownership, signing/provenance, tags and publication not performed |

The Firefox failure matches the startup class discussed in
[Playwright issue 42768](https://github.com/microsoft/playwright/issues/42768),
but this checkout does not establish its OS-level root cause. It is not counted
as a passing browser result, and no macOS privacy permissions or personal
browser profiles were changed. Browser tooling was updated to the stable
[Playwright 1.64.1 release](https://github.com/microsoft/playwright/releases/tag/v1.64.1).

All test counts above refer to checks run during this implementation pass, not
copied historical results. A green local suite does not prove absence of defects
or certify platform/release operations listed as unverified.

## Reproduce and use the candidate

From the repository root:

```bash
Scripts/check_cross_platform.sh
npm --prefix Platforms/Web run test:browser
INNO_BROWSER=webkit npm --prefix Platforms/Web run test:browser
# On a host with all engines available; Firefox failure remains a hard failure:
npm --prefix Platforms/Web run test:browsers
# Explicit connected device/emulator, after the minified consumer build:
node Scripts/check_android_device_smoke.mjs <adb-serial>
```

Build an installable bundle with:

```bash
bash Scripts/prepare_cross_platform_release.sh
```

It runs all portable gates, refuses sources changed during validation, and
creates a new `output/innonetwork-1.0.0.*` folder containing:

- `maven/`: four complete 1.0.0 modules with sources, docs, metadata and checksums;
- `npm/innosquad-innonetwork-1.0.0.tgz`: actual installable Web package;
- `SOURCE_SHA256SUMS`: the reviewed cross-platform source identity;
- `receipt.json`: base revision, dirty-source flag, runtime, and local gate result;
- `SHA256SUMS`: bundle artifact integrity checks.

Use `maven { url = uri("/absolute/path/to/bundle/maven") }` in the consumer's
dependency resolution settings, and depend on
`com.innosquad.innonetwork:innonetwork:1.0.0` plus the optional modules. Install
the npm tarball directly with `npm install /absolute/path/to/bundle/npm/innosquad-innonetwork-1.0.0.tgz`.
These local distributions need no public registry credentials. Checksums are
integrity records, not publisher signatures. Remote release qualification,
including Firefox on Linux, must be completed before declaring a public release.

## Native contracts consulted

- [Fetch Standard](https://fetch.spec.whatwg.org/): decoded response bodies and bodyless HTTP responses.
- [Streams Standard](https://streams.spec.whatwg.org/): cancellation returns the underlying source's promise.
- [Kotlin cancellable continuations](https://kotlinlang.org/api/kotlinx.coroutines/kotlinx-coroutines-core/kotlinx.coroutines/suspend-cancellable-coroutine.html): prompt cancellation and resource handoff.
- [React StrictMode](https://react.dev/reference/react/StrictMode): effect setup/cleanup replay.
