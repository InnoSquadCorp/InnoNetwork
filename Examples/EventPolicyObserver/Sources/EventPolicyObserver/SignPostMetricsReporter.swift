import Foundation
import os.signpost
import InnoNetwork


/// Reference implementation of `EventPipelineMetricsReporting` that emits
/// OSLog SignPost events so Instruments' *Points of Interest* track shows
/// per-delivery latency samples and overflow markers alongside the
/// library's own activity.
///
/// Launch Instruments → *Points of Interest*, attach to your app, filter
/// by subsystem `com.example.event-policy`, and you will see:
///
/// - `delivery` events for `consumerDeliveryLatency` samples (with a
///   `latency` metadata field in milliseconds).
/// - `overflow` events for partition / consumer drops.
///
/// Aggregate snapshots are emitted as points rather than intervals — they
/// are periodic rollups rather than bounded spans.
public struct SignPostMetricsReporter: EventPipelineMetricsReporting {

    private let signposter: OSSignposter

    public init(subsystem: String = "com.example.event-policy") {
        self.signposter = OSSignposter(
            subsystem: subsystem,
            category: .pointsOfInterest
        )
    }

    public func report(_ metric: EventPipelineMetric) {
        switch metric {
        case .consumerDeliveryLatency(let latency):
            let id = signposter.makeSignpostID()
            let latencyMs = Int(latency.latency * 1_000)
            signposter.emitEvent(
                "delivery",
                id: id,
                "partition=\(latency.partitionID, privacy: .public) consumer=\(latency.consumerID, privacy: .public) latency_ms=\(latencyMs)"
            )
        case .partitionState(let state) where state.droppedEventCount > 0:
            let id = signposter.makeSignpostID()
            signposter.emitEvent(
                "overflow",
                id: id,
                "kind=partition id=\(state.partitionID, privacy: .public) dropped=\(state.droppedEventCount)"
            )
        case .consumerState(let state) where state.droppedEventCount > 0:
            let id = signposter.makeSignpostID()
            signposter.emitEvent(
                "overflow",
                id: id,
                "kind=consumer partition=\(state.partitionID, privacy: .public) consumer=\(state.consumerID, privacy: .public) dropped=\(state.droppedEventCount)"
            )
        case .aggregateSnapshot(let snapshot):
            let id = signposter.makeSignpostID()
            signposter.emitEvent(
                "snapshot",
                id: id,
                "kind=\(snapshot.hubKind.rawValue, privacy: .public) maxDepth=\(snapshot.maxQueueDepth) dropped=\(snapshot.totalDroppedEventCount)"
            )
        default:
            break
        }
    }
}
