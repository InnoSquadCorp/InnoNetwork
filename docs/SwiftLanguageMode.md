# Swift 6.2+ language-mode audit

This note records which Swift 6.2+ language-mode features were reviewed for
InnoNetwork while preparing the `4.0.0` release, and which of them
resulted in concrete code changes.

The evaluation criterion is deliberately strict: a feature is only
adopted when there is a **benchmarked win** or an unambiguous readability
improvement that does not trade off safety. Investigations that stayed
speculative are recorded here as follow-ups — they can be revisited when
a benchmark or a real-world report shows they would pay for themselves.

As of the `4.0.0` documentation alignment, **no production source was modified
by this audit.** The package continues to ship on `swiftLanguageMode(.v6)` with
the strict concurrency posture expected for the current public release.

## Reviewed areas

### FIFOBuffer → InlineArray / Span

`Sources/InnoNetwork/FIFOBuffer.swift` holds the event-pipeline queue that
`TaskEventHub` drains per partition. Two Swift 6.2+ additions were
considered:

- `InlineArray<N, Element>` (fixed-size, stack-allocated). The buffer is
  sized by `maxBufferedEventsPerPartition`, a runtime value — so a
  compile-time fixed `N` would force consumers to pick a single ceiling
  at build time instead of via `EventDeliveryPolicy`. **Rejected.**
- `Span<Element>` / `MutableSpan<Element>` to read from the buffer without
  copying. The public surface does not expose slice views of the queue;
  consumers get individual events through callbacks. A span-based API
  would change the public contract for marginal (or zero) win on the
  current workload. **Rejected.**

**Follow-up**: neither is worth pursuing without evidence that
`FIFOBuffer` allocation is a measurable cost under benchmark pressure.

### `@concurrent` attribute

Swift 6.2 introduced `@concurrent` for functions that can run outside the
caller's isolation domain. Reviewed hot paths:

- `WebSocketHeartbeatCoordinator` loop body — already uses structured
  concurrency correctly, no benefit to marking paths `@concurrent`.
- `WebSocketReconnectCoordinator.attemptReconnect` — wrapped in
  `Task { }` already; re-annotating would make the intent noisier, not
  clearer.
- `DownloadFailureCoordinator.handleError` — awaits on injected clock
  and network monitor; no concurrent execution to annotate.

**Rejected.** `@concurrent` adds value when an async function's work can
genuinely run in parallel with the caller's domain. The coordinators we
reviewed do not have that shape — they run inside a single runtime task
per download/socket.

**Follow-up**: benchmark-driven revisit if a hot path shows serialization
in Instruments.

### Task-local values

A task-local `TraceID` (or `SpanID`) would unlock OpenTelemetry-style
correlation without threading extra arguments through public APIs. This
is closest in value to the remaining Tier 3 Observer / Tracer work, but
that feature still needs an RFC to settle the public contract first.

**Deferred.** Tracked as a future observer / tracer candidate in the roadmap.

### Other

- Non-copyable types (`~Copyable`): no candidate production type needs
  move-only semantics. Reviewed `StubWebSocketURLTask`, `TestClock`, and
  the hub partition state — all benefit from copy-by-reference via
  actor/lock isolation.
- Parameter packs: no variadic-generic consumer API changes in-flight.
- Typed throws on public APIs: would be a breaking signature change;
  considered only when a specific throwing surface has a clearly small
  error set. None spotted for the 4.0.0 contract.

## Process note

The audit was timeboxed and reviewed through code reading plus
`InnoNetworkBenchmarks`. Later benchmark governance added focused guards for
request pipeline, request coalescing, response cache, download restore, event
delivery, and WebSocket lifecycle/send hot paths. If one of those guarded
paths regresses in the scheduled benchmark workflow, the corresponding rejected
option above becomes a candidate for a focused follow-up PR with benchmark
numbers attached.
