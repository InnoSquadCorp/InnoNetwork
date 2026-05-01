# Observability exporters

Bridge ``NetworkObservability`` events into vendor SDKs (Sentry,
OpenTelemetry, Pulse, Datadog) through external adapter packages
without coupling the core library to any specific telemetry vendor.

## Why adapters live outside this package

InnoNetwork's observability surface is intentionally vendor-neutral.
``NetworkObservability`` exposes structured events (request lifecycle,
retry decisions, cache outcomes, refresh cycles) as a closure-based
hook. A vendor SDK adapter is glue code: it forwards those events to
the vendor's tracer/span/breadcrumb API in the format the vendor
expects.

Putting that glue inside InnoNetwork would either pull every supported
vendor into the package graph (build-time cost, transitive license
exposure) or fragment the API behind compile-time flags. The vendor
adapter pattern keeps the core surface small and lets each adapter
ship at the cadence of its underlying vendor SDK.

## Adapter shape

A typical adapter is a small product that depends on InnoNetwork plus
the vendor SDK and exposes a single factory:

```swift
import InnoNetwork
import Sentry

public struct SentryNetworkObservability {
    public static func make() -> NetworkObservability {
        NetworkObservability(
            onEvent: { event in
                switch event {
                case .requestStarted(let context):
                    SentrySDK.startTransaction(
                        name: context.path,
                        operation: "http.client"
                    )
                case .requestCompleted(let context, let result):
                    // ...
                    break
                default:
                    break
                }
            }
        )
    }
}
```

The factory returns a ``NetworkObservability`` value the caller
plugs into ``NetworkConfiguration``. The adapter owns:

- Event-to-vendor type mapping (transactions, spans, breadcrumbs).
- Sampling rules — InnoNetwork emits every event; the adapter decides
  what to forward.
- Vendor-specific lifecycle (transaction commit, breadcrumb buffer
  flush) tied to the configuration's request boundaries.

## Example sketches

### OpenTelemetry

Map each ``NetworkObservability/Event/requestStarted`` to a span,
decorate it with `http.method` / `http.url` / `http.status_code`
attributes from the matching ``NetworkObservability/Event/requestCompleted``,
and end the span on success or failure. Retry attempts become child
spans of the original request span so the trace tree shows attempt
count without losing the parent.

### Pulse

Pulse already speaks a structured logging API. The adapter forwards
`requestStarted` / `requestCompleted` directly to a Pulse network
logger and lets the Pulse UI render the rest. Body capture should be
gated by a sampling closure on the adapter — InnoNetwork does not
buffer bodies for observability by default.

### Datadog

Datadog RUM and APM both have HTTP request models. An adapter
typically forwards to RUM's resource API for foreground traffic and
to the tracer for backend-style flows. Retry attempts and refresh
cycles map cleanly to RUM's `addError` and `addAction` surfaces.

### Sentry

Wrap each request in an `SentryTransaction` keyed by the
``APIDefinition`` path. Surface ``NetworkError`` cases as captured
errors with the canonical category as a tag so Sentry's grouping
respects InnoNetwork's classification. Refresh-token cycles
should be breadcrumbs rather than transactions — they're frequent and
not interesting on their own unless they fail.

## Versioning and compatibility

Adapter packages should pin their InnoNetwork dependency to a minor
range (`from: "4.1.0"`) and bump on every observability surface change.
The 4.x line guarantees additive changes to the event enum; an
adapter that uses a `default:` case in its event switch will continue
to compile against newer 4.x releases without modification.
