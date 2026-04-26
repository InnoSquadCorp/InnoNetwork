import Foundation
import os


package final class EventPipelineMetricsReporterProxy: Sendable, EventPipelineMetricsReporting {
    package static let queueCapacity = 1_024

    private let inputContinuation: AsyncStream<EventPipelineMetric>.Continuation
    private let outputContinuation: AsyncStream<EventPipelineMetric>.Continuation
    private let emitToOutput: @Sendable (EventPipelineMetric) -> AsyncStream<EventPipelineMetric>.Continuation.YieldResult
    private let aggregator: EventPipelineMetricsAggregator
    private let dropTracker: EventPipelineMetricsDropTracker
    private let ingestTask: Task<Void, Never>
    private let snapshotTask: Task<Void, Never>
    private let reporterTask: Task<Void, Never>

    package init(
        hubKind: EventPipelineHubKind,
        reporter: any EventPipelineMetricsReporting,
        snapshotInterval: Duration = .seconds(30),
        queueCapacity: Int = EventPipelineMetricsReporterProxy.queueCapacity
    ) {
        let queueCapacity = max(1, queueCapacity)
        let input = AsyncStream<EventPipelineMetric>.makeStream(
            bufferingPolicy: .bufferingNewest(queueCapacity)
        )
        let output = AsyncStream<EventPipelineMetric>.makeStream(
            bufferingPolicy: .bufferingNewest(queueCapacity)
        )
        let aggregator = EventPipelineMetricsAggregator(hubKind: hubKind)
        let dropTracker = EventPipelineMetricsDropTracker()
        let emitToOutput: @Sendable (EventPipelineMetric) -> AsyncStream<EventPipelineMetric>.Continuation.YieldResult = { metric in
            let result = output.continuation.yield(metric)
            if case .dropped = result {
                dropTracker.recordOutputOverflow()
            }
            return result
        }
        let ingestTask = Task {
            for await metric in input.stream {
                let emittedMetrics = await aggregator.ingest(metric)
                for emittedMetric in emittedMetrics {
                    _ = emitToOutput(emittedMetric)
                }
            }
        }
        let snapshotTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: snapshotInterval)
                } catch {
                    return
                }
                let reporterHealth = dropTracker.consumeSnapshot()
                let snapshot = await aggregator.makeSnapshot(
                    totalDroppedMetricCount: reporterHealth.totalDroppedMetricCount,
                    metricsOverflowCount: reporterHealth.metricsOverflowCount
                )
                let result = emitToOutput(.aggregateSnapshot(snapshot))
                switch result {
                case .enqueued, .dropped:
                    // Any overflow caused by emitting the aggregate snapshot itself
                    // belongs to the next window because the current one has already
                    // been consumed atomically above.
                    continue
                case .terminated:
                    return
                @unknown default:
                    return
                }
            }
        }
        let reporterTask = Task {
            for await metric in output.stream {
                reporter.report(metric)
            }
        }

        self.inputContinuation = input.continuation
        self.outputContinuation = output.continuation
        self.emitToOutput = emitToOutput
        self.aggregator = aggregator
        self.dropTracker = dropTracker
        self.ingestTask = ingestTask
        self.snapshotTask = snapshotTask
        self.reporterTask = reporterTask
    }

    deinit {
        shutdown()
    }

    package func report(_ metric: EventPipelineMetric) {
        let result = inputContinuation.yield(metric)
        if case .dropped = result {
            dropTracker.recordInputOverflow()
        }
    }

    package func reportTerminalConsumerState(_ state: EventPipelineConsumerStateMetric) async {
        let emittedMetrics = await aggregator.recordAndEvictTerminalConsumerState(state)
        for emittedMetric in emittedMetrics {
            _ = emitToOutput(emittedMetric)
        }
    }

    package func shutdown() {
        inputContinuation.finish()
        snapshotTask.cancel()
        ingestTask.cancel()
        outputContinuation.finish()
        reporterTask.cancel()
    }
}

private struct EventPipelineMetricsDropSnapshot: Sendable {
    let totalDroppedMetricCount: Int
    let metricsOverflowCount: Int
}

private final class EventPipelineMetricsDropTracker: Sendable {
    private struct State: Sendable {
        var totalDroppedInputMetricCount = 0
        var totalDroppedOutputMetricCount = 0
        var windowDroppedInputMetricCount = 0
        var windowDroppedOutputMetricCount = 0
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: .init())

    func recordInputOverflow() {
        state.withLock {
            $0.totalDroppedInputMetricCount += 1
            $0.windowDroppedInputMetricCount += 1
        }
    }

    func recordOutputOverflow() {
        state.withLock {
            $0.totalDroppedOutputMetricCount += 1
            $0.windowDroppedOutputMetricCount += 1
        }
    }

    func consumeSnapshot() -> EventPipelineMetricsDropSnapshot {
        state.withLock {
            let snapshot = EventPipelineMetricsDropSnapshot(
                totalDroppedMetricCount: $0.totalDroppedInputMetricCount + $0.totalDroppedOutputMetricCount,
                metricsOverflowCount: $0.windowDroppedInputMetricCount + $0.windowDroppedOutputMetricCount
            )
            $0.windowDroppedInputMetricCount = 0
            $0.windowDroppedOutputMetricCount = 0
            return snapshot
        }
    }
}

private actor EventPipelineMetricsAggregator {
    private struct TimedValue<Value: Sendable>: Sendable {
        let value: Value
        let recordedAt: Date
    }

    private let hubKind: EventPipelineHubKind
    private var partitionStates: [String: TimedValue<EventPipelinePartitionStateMetric>] = [:]
    private var consumerStates: [String: TimedValue<EventPipelineConsumerStateMetric>] = [:]
    private var lastPartitionStateEmissionAt: [String: Date] = [:]
    private var lastConsumerStateEmissionAt: [String: Date] = [:]
    private var evictedConsumerKeys: [String: Date] = [:]
    private var latencyValues: [TimeInterval] = []
    private var lowLatencyEmissionCounter: UInt64 = 0
    private var totalDroppedEventCount = 0
    private var overflowEventCount = 0

    init(hubKind: EventPipelineHubKind) {
        self.hubKind = hubKind
    }

    func ingest(_ metric: EventPipelineMetric, now: Date = .now) -> [EventPipelineMetric] {
        switch metric {
        case .partitionState(let state):
            return ingestPartitionState(state, now: now)
        case .consumerState(let state):
            return ingestConsumerState(state, now: now)
        case .consumerDeliveryLatency(let latency):
            return ingestLatency(latency)
        case .aggregateSnapshot:
            return [metric]
        }
    }

    func makeSnapshot(
        now: Date = .now,
        totalDroppedMetricCount: Int = 0,
        metricsOverflowCount: Int = 0
    ) -> EventPipelineAggregateSnapshotMetric {
        let activeWindow: TimeInterval = 60

        pruneEvictedConsumerKeys(now: now, activeWindow: activeWindow)
        partitionStates = partitionStates.filter {
            now.timeIntervalSince($0.value.recordedAt) <= activeWindow
        }
        consumerStates = consumerStates.filter {
            now.timeIntervalSince($0.value.recordedAt) <= activeWindow
        }

        let maxPartitionDepth = partitionStates.values.map(\.value.queueDepth).max() ?? 0
        let maxConsumerDepth = consumerStates.values.map(\.value.queueDepth).max() ?? 0
        let sortedLatencies = latencyValues.sorted()
        let snapshot = EventPipelineAggregateSnapshotMetric(
            hubKind: hubKind,
            activePartitionCount: partitionStates.count,
            activeConsumerCount: consumerStates.count,
            totalDroppedEventCount: totalDroppedEventCount,
            totalDroppedMetricCount: totalDroppedMetricCount,
            maxQueueDepth: max(maxPartitionDepth, maxConsumerDepth),
            p50DeliveryLatency: percentile(0.5, values: sortedLatencies),
            p95DeliveryLatency: percentile(0.95, values: sortedLatencies),
            overflowEventCount: overflowEventCount,
            metricsOverflowCount: metricsOverflowCount
        )
        overflowEventCount = 0
        latencyValues.removeAll(keepingCapacity: true)
        return snapshot
    }

    func recordAndEvictTerminalConsumerState(
        _ state: EventPipelineConsumerStateMetric,
        now: Date = .now
    ) -> [EventPipelineMetric] {
        let key = consumerStateKey(partitionID: state.partitionID, consumerID: state.consumerID)
        evictedConsumerKeys.removeValue(forKey: key)
        let emittedMetrics = ingestConsumerState(state, now: now, forceEmit: true)
        consumerStates.removeValue(forKey: key)
        lastConsumerStateEmissionAt.removeValue(forKey: key)
        evictedConsumerKeys[key] = now
        return emittedMetrics
    }

    private func ingestPartitionState(
        _ state: EventPipelinePartitionStateMetric,
        now: Date
    ) -> [EventPipelineMetric] {
        let previousDropped = partitionStates[state.partitionID]?.value.droppedEventCount ?? 0
        partitionStates[state.partitionID] = TimedValue(value: state, recordedAt: now)

        let droppedDelta = max(0, state.droppedEventCount - previousDropped)
        if droppedDelta > 0 {
            totalDroppedEventCount += droppedDelta
            overflowEventCount += droppedDelta
            lastPartitionStateEmissionAt[state.partitionID] = now
            return [.partitionState(state)]
        }

        let lastEmission = lastPartitionStateEmissionAt[state.partitionID]
        guard shouldEmitStateMetric(lastEmissionAt: lastEmission, now: now) else {
            return []
        }
        lastPartitionStateEmissionAt[state.partitionID] = now
        return [.partitionState(state)]
    }

    private func ingestConsumerState(
        _ state: EventPipelineConsumerStateMetric,
        now: Date,
        forceEmit: Bool = false
    ) -> [EventPipelineMetric] {
        let key = consumerStateKey(partitionID: state.partitionID, consumerID: state.consumerID)
        guard forceEmit || evictedConsumerKeys[key] == nil else {
            return []
        }
        let previousDropped = consumerStates[key]?.value.droppedEventCount ?? 0
        consumerStates[key] = TimedValue(value: state, recordedAt: now)

        let droppedDelta = max(0, state.droppedEventCount - previousDropped)
        if droppedDelta > 0 {
            totalDroppedEventCount += droppedDelta
            overflowEventCount += droppedDelta
            lastConsumerStateEmissionAt[key] = now
            return [.consumerState(state)]
        }

        let lastEmission = lastConsumerStateEmissionAt[key]
        guard forceEmit || shouldEmitStateMetric(lastEmissionAt: lastEmission, now: now) else {
            return []
        }
        lastConsumerStateEmissionAt[key] = now
        return [.consumerState(state)]
    }

    private func ingestLatency(
        _ latency: EventPipelineConsumerDeliveryLatencyMetric
    ) -> [EventPipelineMetric] {
        latencyValues.append(latency.latency)
        if latency.latency >= 0.25 {
            return [.consumerDeliveryLatency(latency)]
        }

        lowLatencyEmissionCounter &+= 1
        if lowLatencyEmissionCounter.isMultiple(of: 64) {
            return [.consumerDeliveryLatency(latency)]
        }
        return []
    }

    private func shouldEmitStateMetric(lastEmissionAt: Date?, now: Date) -> Bool {
        guard let lastEmissionAt else { return true }
        return now.timeIntervalSince(lastEmissionAt) >= 1.0
    }

    private func consumerStateKey(partitionID: String, consumerID: String) -> String {
        "\(partitionID)::\(consumerID)"
    }

    private func pruneEvictedConsumerKeys(now: Date, activeWindow: TimeInterval) {
        evictedConsumerKeys = evictedConsumerKeys.filter {
            now.timeIntervalSince($0.value) <= activeWindow
        }
    }

    private func percentile(_ percentile: Double, values: [TimeInterval]) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        let clampedPercentile = min(1.0, max(0.0, percentile))
        let index = Int((Double(values.count - 1) * clampedPercentile).rounded(.toNearestOrAwayFromZero))
        return values[index]
    }
}
