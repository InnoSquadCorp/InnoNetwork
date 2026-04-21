# EventPolicyObserver

Reference implementations of `EventPipelineMetricsReporting` that
complement the DocC article
[Event delivery policy](../../Sources/InnoNetwork/InnoNetwork.docc/Articles/EventDeliveryPolicy.md).

Three reporters are included and can be wired into any
`WebSocketConfiguration.eventMetricsReporter` or
`DownloadConfiguration.eventMetricsReporter`:

| Reporter | Backing API | Use case |
|---|---|---|
| `LoggerMetricsReporter` | `os.Logger` | Console / unified logging |
| `SignPostMetricsReporter` | `OSSignposter` (Points of Interest) | Instruments tracing |
| `CompositeMetricsReporter` | Fan-out helper | Run both reporters at once |

The sample **does not open real connections** — it only demonstrates
the wiring pattern. `swift build` validates the reporters compile
against the public protocol; `swift run EventPolicyObserver` prints a
short orientation note.

## Running

```bash
# Verify the reporters compile and the configuration wiring is valid
swift build

# Print orientation
swift run EventPolicyObserver
```

## Viewing SignPost events in Instruments

1. Profile your app in Instruments.
2. Pick the *Points of Interest* template.
3. Filter subsystem `com.example.event-policy`.

You should see events named `delivery`, `overflow`, and `snapshot` with
rich metadata (partition ID, consumer ID, latency in ms, drop counts).
The instrumentation cost is intentionally low — only slow deliveries
(`>= 250 ms`) and non-zero drop counts fire, so the reporter stays
usable in production builds.

## swift-metrics bridge

This example intentionally has no external dependencies. A
production-grade bridge to
[swift-metrics](https://github.com/apple/swift-metrics) would look like:

```swift
import Metrics

public struct SwiftMetricsBridge: EventPipelineMetricsReporting {
    private let rttRecorder = Metrics.Recorder(label: "inno_network.delivery_latency_ms")
    private let dropCounter = Metrics.Counter(label: "inno_network.dropped_events")

    public func report(_ metric: EventPipelineMetric) {
        switch metric {
        case .consumerDeliveryLatency(let latency):
            rttRecorder.record(latency.latency * 1_000)
        case .partitionState(let state) where state.droppedEventCount > 0:
            dropCounter.increment(by: state.droppedEventCount)
        case .consumerState(let state) where state.droppedEventCount > 0:
            dropCounter.increment(by: state.droppedEventCount)
        case .aggregateSnapshot, .partitionState, .consumerState:
            break
        }
    }
}
```

Add `swift-metrics` to your own `Package.swift` dependencies and drop
that file in alongside the reporters in this sample.
