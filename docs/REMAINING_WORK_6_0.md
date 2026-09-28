# Remaining 6.0 work

Baseline: `3a87f69`, `codex/6.0-release-hardening`. The user approved the previously
deferred extensions together with the remaining hardening and verification work.
No tag or public release is authorized by this implementation plan.

## Ordered delivery

1. Bound sparse upload callback history without re-adopting late callbacks; reclaim
   only unleased, library-owned resumable snapshots after process death.
2. Add opt-in request cache directives (`no-cache`, `max-age`, `min-fresh`), including
   cache-only, revalidation, stale recovery and asynchronous refresh interactions.
3. Extend the preview OpenAPI generator with typed path arguments, explicit security
   requirements, and a documented composed-schema subset. Reject unsupported forms
   rather than silently weaken authentication or produce misleading models.
4. Exercise sustained streaming/exporter pressure and cancellation with bounded
   buffers and explicit completion barriers; keep local fake-server evidence distinct
   from actual service behavior.
5. Verify physical-device background restoration/file protection and actual backend
   quota/authentication/resume behavior when the user supplies the device and service
   contract. Missing external access remains an open gate, not a pass.
6. Reconcile public API inventory, stability ledger, guides and release notes; run
   generated-client checks, relevant integration tests and the full package suite.

Each stage gets a focused local commit after validation. Preserve the other InnoNetwork
worktrees. A passing local candidate is not evidence of remote CI, consumer migration,
device verification or publication.

## Completion evidence

- Stage 1: upload suites passed (48 tests), and both fresh-process recovery
  fixtures passed including orphan reclamation. The identifier limit is one new
  Provisionally Stable property: 1,615 total / 1,276 provisional declarations.
  Physical-device and real-server checks remain open.
- Stage 2: 131 cache/resilience tests passed, including request constraints,
  opt-in controls, both cache-only wrapper orders, 304 validation and stale-error
  refusal. The new policy case is Provisionally Stable: 1,616 total / 1,277
  provisional declarations; Stable remains 306 and SPI remains 33.
- Stage 3: generator supports declared scalar path parameters, inherited and
  overridden HTTP bearer requirements, object allOf, named discriminated oneOf,
  and nullable properties. Unsupported security/composition forms fail rather
  than weaken a contract. Full OpenAPI/JSON Schema validation is not claimed.
  Unit tests, generated-client typechecking and generated Codable execution
  cover the supported subset.
- Stage 4: two 30-second component workloads passed. A blocked exporter received
  4,847,266 completed attempts, with at most 32 buffered spans and exact
  exported-plus-dropped accounting. Backpressured streaming delivered 4,114,034
  ordered values and cancelled cleanly. The full preflight now repeats this
  bounded-duration gate; ordinary tests use 1,000 iterations. These state-size
  assertions are not an application RSS trend or a real exporter certification.
- Stage 5: BLOCKED on external prerequisites. xctrace reports the physical iPhone
  offline; no disposable backend account, endpoint or quota/IdP contract has been
  supplied. Both prerequisites were requested. No device installation or server
  mutation was attempted.
- Stage 6: full macOS suite passed (1,845 actual passes; 4 explicit external skips),
  iOS Simulator whole-package build passed, generator tests passed (20), and
  generated output typecheck/roundtrip passed. Final docs/API/release fixtures and
  formatting are recorded in the release validation document. Remote CI,
  final consumer builds, and tvOS/watchOS/visionOS were not rerun for this candidate.
