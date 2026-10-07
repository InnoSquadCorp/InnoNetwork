# CI impact preparation

Status: draft PR for review, rebased onto main `44e4ca28c50c03f817231a077c0f3bdfdbc859c8`. Repository protection, variables and release settings are outside this change. Product selection, job cancellation, cleanup writes and main-moved reuse require separate opt-in activation.

## Implemented PR path

An ordinary PR containing only modified, regular allowlisted Markdown or `.github/FUNDING.yml` files may use compiler-free static policy checks. Exact merge-base/head Git blob IDs and code signatures are recorded. CI Required re-reads the immutable event anchors, recomputes the complete changed-file inventory and blob proof, and rejects missing, failed, cancelled or unexpectedly skipped results. The required check has no workflow-level path filter.

All code fences and indented code are protected. Unproven blobs, executable changes, opaque HTML/DocC directives, release metadata, unknown or mixed changes, deleted/renamed/mode-changed files are conservative. Missing diff evidence selects full validation. The release-validation label remains full. Main, merge queue, manual and release gates retain their previous full semantics, including exact-tree proof rules.

Native `parallel` is limited to reviewed independent read-only policy checks. No SwiftPM build, shared `.build`, DerivedData, Package.resolved mutation, sanitizer or performance workload is overlapped. Native groups have an implicit join: every child must finish successfully. No error-tolerance or conditional native children are introduced.

## Linter compatibility

`native_parallel.py` accepts a deliberately small schema: 2–10 named run-only children, optional shell/timeout, no nested native controls, IDs, environment publishing, output dependencies, conditional or continue-on-error children. It produces a same-line-count serial projection only for actionlint 1.7.12. GitHub executes the original YAML. All ordinary actionlint diagnostics remain enforced; only the existing exact-position concurrency.queue exception remains. Negative tests reject malformed schemas. Real hosted parallel-child REST step inventory must be verified before rollout; the bot and main-reuse evidence checks remain fail-closed.

## Executable opt-in product selection

The reviewed inventory contains 26 package targets, 10 products and 17 checked-in consumer fixture/package entries. It is bound to the exact Package.swift SHA-256. Local target dependencies include a conservative union of conditional edges. External package dependencies and full manifest semantics are unchanged.

`Scripts/ci-product-impact.py` computes changed targets, reverse-dependent products/tests/consumers, and a separate test compilation dependency closure. Unknown paths, generated files, resources, manifest/toolchain/plugin/shared-support changes and mixed evidence retain full fallback. Use `--verify-dump` against an actual Apple SwiftPM dump before using the map operationally.

`Scripts/ci-product-impact.py` is the planner; the separate `Scripts/ci_product_execution.py` adapter is now wired into existing workflows. `INNONETWORK_PRODUCT_CI=true` is required to admit narrowed ordinary PR builds. Admission rechecks the exact checkout/event/merge parents, complete Git diff, clean tracked and relevant untracked inputs, committed dependency lock, graph/manifest identity and real SwiftPM dump. Missing evidence executes the original full recipe. No manifest is rewritten. Exact command/result receipts are recomputed before acceptance; missing, forged, stale or failed receipts cannot grant success.

The existing Build step uses native swift build --target for the affected product closure. Existing complete tests, coverage, consumer, platform and release gates remain full. The verified prose-only lane also runs check_docs_contract_sync.sh --static-only, including literal prose, release-state, public API budget and source-ledger checks. The default script invocation still requires compiler-derived product/symbol checks.

Full `swift test` remains explicit: `--filter` alone does not prove a narrower test compilation graph. Separate test packages or independently validated native bundle execution are needed before promising product-only test compilation. Existing full coverage and release gates are retained.

Examples to inspect:
- AWS: mode=scoped-build-plan; affected products=InnoNetworkAuthAWS; affected tests=InnoNetworkAuthAWSTests; test-build products=InnoNetwork, InnoNetworkAuthAWS, InnoNetworkMacroSupport
- Upload: mode=scoped-build-plan; affected products=InnoNetworkUpload; affected tests=InnoNetworkUploadTests; test-build products=InnoNetwork, InnoNetworkDownload, InnoNetworkMacroSupport, InnoNetworkPersistentCache, InnoNetworkTestSupport, InnoNetworkUpload, InnoNetworkWebSocket
- Download: mode=scoped-build-plan; affected products=InnoNetworkDownload, InnoNetworkTestSupport; affected tests=InnoNetworkDownloadTests, InnoNetworkLiveTests, InnoNetworkMacroTests, InnoNetworkTests, InnoNetworkUploadTests, InnoNetworkWebSocketTests; test-build products=InnoNetwork, InnoNetworkDownload, InnoNetworkMacroSupport, InnoNetworkOpenAPI, InnoNetworkPersistentCache, InnoNetworkTestSupport, InnoNetworkTrust, InnoNetworkUpload, InnoNetworkWebSocket
- shared core: mode=full; affected products=InnoNetwork, InnoNetworkAuthAWS, InnoNetworkDownload, InnoNetworkMacroSupport, InnoNetworkOpenAPI, InnoNetworkPersistentCache, InnoNetworkTestSupport, InnoNetworkTrust, InnoNetworkUpload, InnoNetworkWebSocket; affected tests=InnoNetworkAuthAWSTests, InnoNetworkDownloadTests, InnoNetworkLiveTests, InnoNetworkMacroTests, InnoNetworkPersistentCacheTests, InnoNetworkTests, InnoNetworkUploadTests, InnoNetworkWebSocketTests; test-build products=InnoNetwork, InnoNetworkAuthAWS, InnoNetworkDownload, InnoNetworkMacroSupport, InnoNetworkOpenAPI, InnoNetworkPersistentCache, InnoNetworkTestSupport, InnoNetworkTrust, InnoNetworkUpload, InnoNetworkWebSocket

## Before any remote rollout

1. Keep these changes based on the intended final repository SHA and rerun affected policy tests when it moves.
2. Run Apple SwiftPM dump verification, actual target builds, complete test discovery and full release gates. This VM has no Swift/Xcode.
3. Validate real GitHub native parallel execution, failure/cancellation propagation and REST job-step names with an explicitly authorized non-release run. Do not infer these from a linter pass.
4. Review required-check and proof migration together. No repository settings are changed by this preparation.
5. Measure runner queue time separately from actual execution; no speed or cost reduction is claimed.

The existing Ruby 3.3.8 runtime under flow-review-tools/bin can run Ruby-dependent policy tests when added to PATH. Compiler-free tests and YAML checks do not substitute for Apple or hosted validation.

## Draft validation on 2026-10-07

The publication candidate on the base above passes 332 automation tests, 133 Python script tests, the real Ruby 3.3.8 consumer contract suite (12 tests / 44 assertions), the changelog, Periphery and post-release documentation fixtures, static documentation/public-operations checks, and checksum-pinned actionlint 1.7.12 for 16 workflows. Mocked Swift/API fixtures establish command selection and failure propagation only.

Full Mac runtime validation is incomplete. Earlier MIME (16) and trust (16) failures were reproduced on the exact original base `057a2f92239c1d88abae24a9ac28017275aa313d`. Cache (4), connection (10) and Download (162) results remain unresolved, with execution-permission blockers. These results do not establish a passing full test suite for this PR or its new base. This publication VM has no Swift/Xcode; actual SwiftPM dump/target builds, full discovery/runtime, consumer and release validation remain required.
