# Candidate pre-release hardening and app validation

Status: Draft technical record; implementation authorized by the maintainer on
2026-09-30. This is not a design-review sign-off or publication approval.
One-page depth: two local storage contracts plus an independently built app.

## Baseline and decisions

- Core input: `7d46c68dd8a6793e9908757e2c3f342d2a530092`.
- Protobuf input: `35d30a8ef0a936a0e43bafc77c0e7fe9acf787c3`.
- Telemetry currently retains one event per eviction batch indefinitely.
  Aggregate by eviction reason between drains (five current reasons), with
  saturating counts/bytes and first-observed reason order. Do not drop totals
  silently or add an unbounded chronological event stream. The alternative,
  a configurable ring with a drop counter, loses totals and adds public knobs.
- The cache index is actor-local, not a multi-writer database. Document one
  active owner per directory, including app extensions/processes. Share the
  actor inside a process; partition directories across independent owners.
  No interprocess lock or concurrent-directory support is claimed. Implementing
  multi-process ownership enforcement/lifecycle is a separate API design, not
  implied by an App Group URL helper or the existing actor isolation.
- Build a macro-first JSON/protobuf sample against the local unpublished pair.
  Exercise URLSession through a real loopback socket and real sandbox files;
  fixtures are not an operational IdP, AWS service, or production backend.
  Persist a small synthetic record and verify it after relaunch.

## Delivery and exit criteria

1. Aggregate telemetry and document ownership; test repeated/alternating reasons,
   saturation, drain epochs, concurrent cache calls and normal cache behavior.
2. Build and run a standalone iOS sample; capture device/runtime, launch/UI and
   scenario results. Explicitly separate physical device and simulator evidence.
3. Run affected regressions and local pre-release gates against final sources;
   preserve the earlier failure logs and performance raw data.
4. Push final candidates once and create Draft PRs (authorized separately in this
   conversation). Read exact-SHA CI results, without merging, tagging or publishing.

No consumer application migration, remote service provisioning, signing-account
change, threshold relaxation or automation is authorized. The public core 6.1
tag is not yet available; paired-candidate validation must not be labeled a
published-dependency check. Xcode 26 and remote CI remain separate gates.

## Fresh source and execution evidence

Runtime/test source: core `d1b4d9376f601dae918b114b088447c3ce9c519a`.
The sample source is adapter `c45ea736745cb30abf1098a736b1f18eccfc81e2`.
Subsequent candidate notes and evidence commits change documentation/CI only;
they do not replace the measured source with untested runtime changes.
Local toolchain: Xcode 27.0 / Swift 6.4. Artifacts and original failed sample
build logs are preserved under `.build/pre-release-app-20260930/`; the prior
preflight output was preserved in its `prior-preflight/` directory before the
fresh full run. Prior remediation evidence is separate in
`REMEDIATION_2026_09_30.md`, not silently counted as fresh here.

| Gate | Fresh evidence |
| --- | --- |
| Focused telemetry/cache regressions | 87 tests pass, including 50,000 alternating events, independent saturation, drain epochs and 128 concurrent actor calls. |
| Full TSAN | 1,989 registered: 1,985 ordinary passes and four explicit opt-in live skips. No sanitizer failure. The slow download persistence suite completed; its process sample and full log are retained. |
| Bounded shards and serial coverage | All four shards and serial coverage pass with the same 1,989-test inventory, not added as unique test coverage. Runtime line coverage 89.00%; compiler-host macro line coverage 79.55%, separately reported. |
| Companion | 43 runtime and two macro tests pass, with 22 compiler rejections and two passing controls, docs contracts and release-gate fixtures. |
| Physical sample | iPhone 14 Pro Max, iOS 27.0.1 (24A446): 7/7 cold, 7/7 separate-process warm and 7/7 final rebuilt app. Warm cache restores with zero network fetches. |
| CLI / simulator boundary | macOS CLI 7/7 cold and 7/7 separate-process warm. iOS Simulator SDK build passes; no simulator execution claimed. |
| Streaming resources | Two 30-second soaks pass: 7,199,614 span attempts exactly accounted; 6,261,849 ordered deliveries, followed by completed cancellation. |
| Performance | All 14 runtime and five JSON guards pass at the unchanged 20% limit, with three interleaved baseline/head pairs per lane. Runtime baseline `a4aaaba8b41553033f5d1f23fa94af85b52b4c3a`; JSON baseline `b358692e1e583b5cef1c97bb65208729b313f574`. No retry, exemption or baseline change in this run. |

Performance raw samples are in `.build/local-release-preflight/benchmarks/` and
its `json/` subdirectory. Worst paired median deltas: runtime cache lookup
-1.0848% (51.8761 percentage-point pair spread); JSON anyOf all matches -8.7448%
(1.4283 pp spread). Another repository's preflight/build was observed on the same
Mac during the runtime samples; it was not interrupted. The wide runtime spread
limits interpretation: passing the guard is not proof of a precise speedup or
an isolated-host measurement. Exact-head remote performance remains required.

The sample uses macro-first JSON and protobuf endpoints over a real loopback TCP
fixture and URLSession, not a mock transport. Scenarios cover binary echo, exact
503 retry count, a streaming byte cap, cancellation after server admission,
persistent restoration and bounded telemetry. It is maintained in the companion
repository at `Examples/ValidationApp`. No signing team/profile/device identifier
is committed. Only synthetic JSON reports are retained as shareable evidence;
a device screenshot containing an unrelated picture-in-picture overlay was
deleted rather than published or counted as complete UI testing.

The fresh `bash Scripts/run_local_release_preflight.sh --full` command completed
with **exit 0, all fourteen gates passed**. Unlike the earlier remediation run,
this is a single successful full invocation, not a resumed failure. Evidence is
`full-preflight.log` in the artifact directory above and the current
`.build/local-release-preflight/` output:

- Release/CI negative fixtures, dependency lock, formatting, API budget/tier/enum
  and documentation contracts pass (1,764 runtime plus 12 host declarations).
- All eleven core consumer packages, actual stable/migration/doc examples,
  macro/OpenAPI generation and generated-output compile/runtime checks pass.
- SBOMs and DocC archive verification pass for all ten public products.
- macOS and iOS Simulator Xcode builds pass; all ten public library targets
  build for tvOS, watchOS and visionOS. These are SDK builds, not execution on
  those devices.

Final documentation-only follow-ups preserve the runtime/test/package/benchmark
source above. Remote evidence will be attached to the exact pushed candidate,
not inferred from this local run. No final-main/manual Release validation, tag
or publication was performed in this phase.

## Remaining boundaries

The legacy `6.0-release-state: OK (ready)` output checks the historical 6.0
contract, not this later encoded-request candidate's release approval. Its own
[candidate notes](releases/6.1.0-encoded-request-candidate.md) remain Draft.
The public core 6.1 tag is absent; normal companion CI/public resolution remains
a separate publication dependency. Pinned paired-candidate CI is additional
exact-source evidence, not a bypass of the public release gate.

Physical loopback does not certify external TLS/pinning, OS background-session
restoration, locked-device protection or target IdP/exporter/AWS/FairPlay services.
No full UI/accessibility acceptance, consumer app source migration or multi-writer
cache support is claimed. Earlier WebSocket performance anomalies remain
unexplained; later passing guards do not retroactively diagnose them. A green
suite does not prove the absence of further defects.
