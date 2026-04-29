import Foundation
import InnoNetwork
import InnoNetworkDownload
import InnoNetworkWebSocket

// MARK: - Wiring demonstration
//
// This executable does not open real connections — its purpose is to
// show how `EventPipelineMetricsReporting` implementations plug into the
// existing configuration surfaces. Running `swift build` validates that
// the reporters compile against the public protocol; running
// `swift run EventPolicyObserver` prints a short orientation note.

let logger = LoggerMetricsReporter()
let signpost = SignPostMetricsReporter()
let composite = CompositeMetricsReporter([logger, signpost])

// Compile-time wiring sample only; real code passes this into a manager.
// let webSocketManager = WebSocketManager(configuration: webSocketConfig)
let webSocketConfig = WebSocketConfiguration.advanced {
    $0.eventDeliveryPolicy = EventDeliveryPolicy(
        maxBufferedEventsPerPartition: 1024,
        maxBufferedEventsPerConsumer: 512,
        overflowPolicy: .dropOldest
    )
    $0.eventMetricsReporter = composite
}

// Compile-time wiring sample only; real code passes this into a manager.
// let downloadManager = try DownloadManager(configuration: downloadConfig)
let downloadConfig = DownloadConfiguration.advanced {
    $0.eventMetricsReporter = logger
}

let note = """
    EventPolicyObserver sample
    --------------------------
    This sample wires three reference reporters behind the public
    `EventPipelineMetricsReporting` protocol:

      • LoggerMetricsReporter     — os.Logger, subsystem "com.example.event-policy"
      • SignPostMetricsReporter   — OSLog SignPost (Instruments → Points of Interest)
      • CompositeMetricsReporter  — fan-out helper

    The WebSocket configuration above attaches the composite reporter; the
    Download configuration attaches only the Logger reporter. Both values
    are consumed by the library when you pass them into
    `WebSocketManager(configuration:)` / `DownloadManager(configuration:)`.

    Run:
      swift build                 # verify the reporters compile
      swift run EventPolicyObserver

    For a swift-metrics bridge, see the inline comment in
    `CompositeMetricsReporter.swift` — a production implementation would
    forward `.consumerDeliveryLatency` samples into a `Metrics.Recorder`
    without introducing that dependency in this sample.
    """

print(note)

// Keep the compiler from warning about unused bindings. In real usage
// these configurations flow into `WebSocketManager` / `DownloadManager`
// initializers.
_ = webSocketConfig
_ = downloadConfig
