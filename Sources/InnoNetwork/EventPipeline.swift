import Foundation

public enum EventPipelineHubKind: String, Sendable {
    case genericTask
    case networkRequest
    case downloadTask
    case webSocketTask
}

public enum EventPipelineOverflowPolicy: Sendable {
    case dropOldest
    case dropNewest
}

public struct EventDeliveryPolicy: Sendable {
    public let maxBufferedEventsPerPartition: Int
    public let maxBufferedEventsPerConsumer: Int
    public let overflowPolicy: EventPipelineOverflowPolicy

    public init(
        maxBufferedEventsPerPartition: Int = 100,
        maxBufferedEventsPerConsumer: Int = 100,
        overflowPolicy: EventPipelineOverflowPolicy = .dropOldest
    ) {
        self.maxBufferedEventsPerPartition = max(1, maxBufferedEventsPerPartition)
        self.maxBufferedEventsPerConsumer = max(1, maxBufferedEventsPerConsumer)
        self.overflowPolicy = overflowPolicy
    }

    public static let `default` = EventDeliveryPolicy()
}

public enum EventPipelineMetric: Sendable {
    case partitionState(EventPipelinePartitionStateMetric)
    case consumerState(EventPipelineConsumerStateMetric)
    case consumerDeliveryLatency(EventPipelineConsumerDeliveryLatencyMetric)
    case aggregateSnapshot(EventPipelineAggregateSnapshotMetric)
}

public struct EventPipelinePartitionStateMetric: Sendable {
    public let partitionID: String
    public let queueDepth: Int
    public let droppedEventCount: Int
    public let oldestQueuedEventAge: TimeInterval?

    public init(
        partitionID: String,
        queueDepth: Int,
        droppedEventCount: Int,
        oldestQueuedEventAge: TimeInterval?
    ) {
        self.partitionID = partitionID
        self.queueDepth = queueDepth
        self.droppedEventCount = droppedEventCount
        self.oldestQueuedEventAge = oldestQueuedEventAge
    }
}

public struct EventPipelineConsumerStateMetric: Sendable {
    public let partitionID: String
    public let consumerID: String
    public let queueDepth: Int
    public let droppedEventCount: Int
    public let oldestQueuedEventAge: TimeInterval?

    public init(
        partitionID: String,
        consumerID: String,
        queueDepth: Int,
        droppedEventCount: Int,
        oldestQueuedEventAge: TimeInterval?
    ) {
        self.partitionID = partitionID
        self.consumerID = consumerID
        self.queueDepth = queueDepth
        self.droppedEventCount = droppedEventCount
        self.oldestQueuedEventAge = oldestQueuedEventAge
    }
}

public struct EventPipelineConsumerDeliveryLatencyMetric: Sendable {
    public let partitionID: String
    public let consumerID: String
    public let latency: TimeInterval

    public init(partitionID: String, consumerID: String, latency: TimeInterval) {
        self.partitionID = partitionID
        self.consumerID = consumerID
        self.latency = latency
    }
}

public struct EventPipelineAggregateSnapshotMetric: Sendable {
    public let hubKind: EventPipelineHubKind
    public let activePartitionCount: Int
    public let activeConsumerCount: Int
    public let totalDroppedEventCount: Int
    public let totalDroppedMetricCount: Int
    public let maxQueueDepth: Int
    public let p50DeliveryLatency: TimeInterval?
    public let p95DeliveryLatency: TimeInterval?
    public let overflowEventCount: Int
    public let metricsOverflowCount: Int

    public init(
        hubKind: EventPipelineHubKind,
        activePartitionCount: Int,
        activeConsumerCount: Int,
        totalDroppedEventCount: Int,
        totalDroppedMetricCount: Int = 0,
        maxQueueDepth: Int,
        p50DeliveryLatency: TimeInterval?,
        p95DeliveryLatency: TimeInterval?,
        overflowEventCount: Int,
        metricsOverflowCount: Int = 0
    ) {
        self.hubKind = hubKind
        self.activePartitionCount = activePartitionCount
        self.activeConsumerCount = activeConsumerCount
        self.totalDroppedEventCount = totalDroppedEventCount
        self.totalDroppedMetricCount = totalDroppedMetricCount
        self.maxQueueDepth = maxQueueDepth
        self.p50DeliveryLatency = p50DeliveryLatency
        self.p95DeliveryLatency = p95DeliveryLatency
        self.overflowEventCount = overflowEventCount
        self.metricsOverflowCount = metricsOverflowCount
    }
}

public protocol EventPipelineMetricsReporting: Sendable {
    func report(_ metric: EventPipelineMetric)
}

public struct NoOpEventPipelineMetricsReporter: EventPipelineMetricsReporting {
    public init() {}

    public func report(_ metric: EventPipelineMetric) {
        _ = metric
    }
}
