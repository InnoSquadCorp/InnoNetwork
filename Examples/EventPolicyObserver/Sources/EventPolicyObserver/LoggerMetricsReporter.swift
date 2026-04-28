import Foundation
import InnoNetwork
import os

/// Reference implementation of `EventPipelineMetricsReporting` backed by
/// `os.Logger`. Routes every metric kind onto a single subsystem/category
/// so the Console.app filter `subsystem == "com.example.event-policy"`
/// surfaces everything the library publishes.
///
/// Use pattern:
///
/// ```swift
/// let configuration = WebSocketConfiguration.advanced {
///     $0.eventMetricsReporter = LoggerMetricsReporter()
/// }
/// ```
///
/// In production you usually want either this **or** `SignPostMetricsReporter`,
/// not both — pick the one that matches your observability stack (log
/// aggregation vs Instruments tracing).
public struct LoggerMetricsReporter: EventPipelineMetricsReporting {

    private let logger: Logger
    private let slowDeliveryThreshold: TimeInterval

    public init(
        subsystem: String = "com.example.event-policy",
        category: String = "metrics",
        slowDeliveryThreshold: TimeInterval = 0.25
    ) {
        self.logger = Logger(subsystem: subsystem, category: category)
        self.slowDeliveryThreshold = slowDeliveryThreshold
    }

    public func report(_ metric: EventPipelineMetric) {
        switch metric {
        case .partitionState(let state):
            if state.droppedEventCount > 0 {
                logger.warning(
                    "partition \(state.partitionID, privacy: .public) depth=\(state.queueDepth) dropped=\(state.droppedEventCount)"
                )
            }
        case .consumerState(let state):
            if state.droppedEventCount > 0 {
                logger.warning(
                    "consumer \(state.partitionID, privacy: .public)/\(state.consumerID, privacy: .public) depth=\(state.queueDepth) dropped=\(state.droppedEventCount)"
                )
            }
        case .consumerDeliveryLatency(let latency):
            // Only log noticeably slow deliveries; routine latency rows are
            // too chatty for a default reporter.
            if latency.latency >= slowDeliveryThreshold {
                logger.notice(
                    "slow delivery \(latency.partitionID, privacy: .public)/\(latency.consumerID, privacy: .public) latency=\(latency.latency)s"
                )
            }
        case .aggregateSnapshot(let snapshot):
            logger.info(
                "snapshot \(snapshot.hubKind.rawValue, privacy: .public) partitions=\(snapshot.activePartitionCount) consumers=\(snapshot.activeConsumerCount) maxDepth=\(snapshot.maxQueueDepth) dropped=\(snapshot.totalDroppedEventCount)"
            )
        }
    }
}
