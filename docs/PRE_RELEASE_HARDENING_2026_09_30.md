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

Evidence and remaining boundaries will be appended after execution. Prior
validation is recorded in `REMEDIATION_2026_09_30.md`, not counted as fresh here.
