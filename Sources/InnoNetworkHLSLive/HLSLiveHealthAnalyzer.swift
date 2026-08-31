import Foundation

/// Reduces delivered live playlist snapshots into deterministic health.
///
/// The analyzer performs no networking, sleeping, or recovery. Give each live
/// session its own mutable analyzer, supply the observation time explicitly,
/// and let the application decide how a health result affects recovery or UI.
public struct HLSLiveHealthAnalyzer: Sendable {
    private let configuration: HLSLiveHealthConfiguration
    private var hasIngestedSnapshot = false
    private var furthestEdgePosition: HLSLiveEdgePosition?
    private var lastPathwayID: String?
    private var newestObservedAt: TimeInterval?
    private var lastAdvancedAt: TimeInterval?
    private var stagnantSnapshotCount = 0
    private var deltaRecoveryCount = 0
    private var pathwayChangeCount = 0
    private var currentSnapshot: HLSLiveHealthSnapshot

    /// Creates an empty live-health analysis session.
    public init(
        configuration: HLSLiveHealthConfiguration = .safeDefaults()
    ) {
        self.configuration = configuration
        self.currentSnapshot = Self.emptySnapshot
    }

    /// The current health snapshot without mutating analysis state.
    public var snapshot: HLSLiveHealthSnapshot {
        currentSnapshot
    }

    /// Ingests one delivered playlist snapshot at a caller-owned time.
    @discardableResult
    public mutating func ingest(
        _ snapshot: HLSLivePlaylistSnapshot,
        observedAt: Date
    ) -> HLSLiveHealthSnapshot {
        let observedTimestamp = finiteTimestamp(observedAt)
        if let observedTimestamp {
            newestObservedAt = max(
                newestObservedAt ?? observedTimestamp,
                observedTimestamp
            )
        }
        let currentEdge = liveEdgePosition(in: snapshot)
        let edgeRegression = updateEdge(
            currentEdge,
            observedTimestamp: observedTimestamp
        )
        if hasIngestedSnapshot,
            snapshot.pathwayID != lastPathwayID
        {
            pathwayChangeCount = incremented(pathwayChangeCount)
        }
        lastPathwayID = snapshot.pathwayID
        if snapshot.reloadMode == .fullReloadRecovery {
            deltaRecoveryCount = incremented(deltaRecoveryCount)
        }
        hasIngestedSnapshot = true

        let edgeDate = estimatedLiveEdgeDate(
            in: snapshot,
            position: currentEdge
        )
        let estimatedLatency = liveLatency(
            observedTimestamp: newestObservedAt,
            edgeDate: edgeDate
        )
        let recommendedLatency = recommendedLatency(
            in: snapshot,
            position: currentEdge
        )
        let estimatedPlaylistAge = estimatedPlaylistAge(
            in: snapshot,
            observedTimestamp: newestObservedAt
        )
        let availableWindowDuration = windowDuration(
            in: snapshot
        )
        let stagnantDuration = finiteDuration(
            from: lastAdvancedAt,
            to: newestObservedAt
        )
        let latencyDrift = estimatedLatency.flatMap { latency in
            recommendedLatency.map { max(0, latency - $0) }
        }
        let thresholds = configuration.thresholds
        let freshness = freshnessStatus(
            estimatedPlaylistAge: estimatedPlaylistAge,
            targetDuration: snapshot.playlist.targetDuration,
            availableWindowDuration: availableWindowDuration,
            isEnded: snapshot.isEnded,
            thresholds: thresholds
        )
        let isWindowAtRisk =
            stagnantDuration > 0
            && availableWindowDuration > 0
            && stagnantDuration + (recommendedLatency ?? 0)
                >= availableWindowDuration

        var issues: [HLSLiveHealthIssue] = []
        if edgeRegression {
            issues.append(.liveEdgeRegression)
        }
        if stagnantSnapshotCount
            >= thresholds.degradedStagnantSnapshotCount
        {
            issues.append(.stagnantLiveEdge)
        }
        if latencyDrift.map({
            $0 >= thresholds.degradedLatencyDrift
        }) == true {
            issues.append(.elevatedLiveLatency)
        }
        if freshness.isStale {
            issues.append(.stalePlaylistResponse)
        }
        if deltaRecoveryCount
            >= thresholds.degradedDeltaRecoveryCount
        {
            issues.append(.repeatedDeltaRecovery)
        }
        if pathwayChangeCount
            >= thresholds.degradedPathwayChangeCount
        {
            issues.append(.pathwayInstability)
        }
        if isWindowAtRisk {
            issues.append(.liveWindowAtRisk)
        }

        let isCritical =
            edgeRegression
            || stagnantSnapshotCount
                >= thresholds.criticalStagnantSnapshotCount
            || latencyDrift.map({
                $0 >= thresholds.criticalLatencyDrift
            }) == true
            || freshness.isCritical
            || isWindowAtRisk
        let status: HLSLiveHealthStatus
        if isCritical {
            status = .critical
        } else if issues.isEmpty {
            status = .healthy
        } else {
            status = .degraded
        }
        currentSnapshot = HLSLiveHealthSnapshot(
            status: status,
            issues: issues,
            observedAt: newestObservedAt.map {
                Date(timeIntervalSinceReferenceDate: $0)
            },
            liveEdgePosition: currentEdge,
            reloadMode: snapshot.reloadMode,
            estimatedLiveEdgeDate: edgeDate,
            estimatedLiveLatency: estimatedLatency,
            recommendedLiveLatency: recommendedLatency,
            estimatedPlaylistAge: estimatedPlaylistAge,
            availableWindowDuration: availableWindowDuration,
            stagnantSnapshotCount: stagnantSnapshotCount,
            stagnantDuration: stagnantDuration,
            deltaRecoveryCount: deltaRecoveryCount,
            pathwayChangeCount: pathwayChangeCount
        )
        return currentSnapshot
    }

    /// Removes all session-level health signals.
    public mutating func reset() {
        hasIngestedSnapshot = false
        furthestEdgePosition = nil
        lastPathwayID = nil
        newestObservedAt = nil
        lastAdvancedAt = nil
        stagnantSnapshotCount = 0
        deltaRecoveryCount = 0
        pathwayChangeCount = 0
        currentSnapshot = Self.emptySnapshot
    }

    private mutating func updateEdge(
        _ position: HLSLiveEdgePosition?,
        observedTimestamp: TimeInterval?
    ) -> Bool {
        guard let position else {
            if hasIngestedSnapshot {
                stagnantSnapshotCount = incremented(
                    stagnantSnapshotCount
                )
            }
            return false
        }
        guard let furthestEdgePosition else {
            self.furthestEdgePosition = position
            lastAdvancedAt = newestObservedAt ?? observedTimestamp
            stagnantSnapshotCount = 0
            return false
        }
        switch compare(position, furthestEdgePosition) {
        case .orderedDescending:
            self.furthestEdgePosition = position
            lastAdvancedAt = newestObservedAt ?? observedTimestamp
            stagnantSnapshotCount = 0
            return false
        case .orderedSame:
            stagnantSnapshotCount = incremented(
                stagnantSnapshotCount
            )
            return false
        case .orderedAscending:
            stagnantSnapshotCount = incremented(
                stagnantSnapshotCount
            )
            return true
        }
    }

    private func liveEdgePosition(
        in snapshot: HLSLivePlaylistSnapshot
    ) -> HLSLiveEdgePosition? {
        let complete = snapshot.segments.last.map {
            HLSLiveEdgePosition(
                mediaSequenceNumber: $0.sequenceNumber,
                partIndex: nil
            )
        }
        let partial = snapshot.partialSegments.max { lhs, rhs in
            compare(
                HLSLiveEdgePosition(
                    mediaSequenceNumber: lhs.mediaSequenceNumber,
                    partIndex: lhs.partIndex
                ),
                HLSLiveEdgePosition(
                    mediaSequenceNumber: rhs.mediaSequenceNumber,
                    partIndex: rhs.partIndex
                )
            ) == .orderedAscending
        }.map {
            HLSLiveEdgePosition(
                mediaSequenceNumber: $0.mediaSequenceNumber,
                partIndex: $0.partIndex
            )
        }
        switch (complete, partial) {
        case (.none, .none):
            return nil
        case (.some(let complete), .none):
            return complete
        case (.none, .some(let partial)):
            return partial
        case (.some(let complete), .some(let partial)):
            return compare(complete, partial) == .orderedAscending
                ? partial
                : complete
        }
    }

    private func estimatedLiveEdgeDate(
        in snapshot: HLSLivePlaylistSnapshot,
        position: HLSLiveEdgePosition?
    ) -> Date? {
        guard let position else {
            return nil
        }
        if position.partIndex == nil,
            let segment = snapshot.segments.last(where: {
                $0.sequenceNumber == position.mediaSequenceNumber
            }),
            let date = segment.programDateTime
        {
            return date.addingTimeInterval(segment.duration)
        }
        guard let partIndex = position.partIndex,
            let complete = snapshot.segments.last,
            let completeDate = complete.programDateTime
        else {
            return nil
        }
        let (expectedSequence, overflow) =
            complete.sequenceNumber.addingReportingOverflow(1)
        guard !overflow,
            position.mediaSequenceNumber == expectedSequence
        else {
            return nil
        }
        let parts = snapshot.partialSegments
            .filter {
                $0.mediaSequenceNumber == position.mediaSequenceNumber
                    && $0.partIndex <= partIndex
                    && !$0.isGap
            }
            .sorted { $0.partIndex < $1.partIndex }
        guard parts.count == partIndex + 1,
            parts.enumerated().allSatisfy({ offset, part in
                part.partIndex == offset
                    && part.duration.isFinite
                    && part.duration > 0
            })
        else {
            return nil
        }
        let partDuration = parts.reduce(0) {
            $0 + $1.duration
        }
        guard partDuration.isFinite else {
            return nil
        }
        return completeDate.addingTimeInterval(
            complete.duration + partDuration
        )
    }

    private func recommendedLatency(
        in snapshot: HLSLivePlaylistSnapshot,
        position: HLSLiveEdgePosition?
    ) -> TimeInterval? {
        let serverControl = snapshot.playlist.lowLatency?
            .serverControl
        let candidate =
            position?.isPartial == true
            ? serverControl?.partialSegmentHoldBack
                ?? serverControl?.holdBack
            : serverControl?.holdBack
        guard let candidate, candidate.isFinite, candidate > 0 else {
            return nil
        }
        return candidate
    }

    private func liveLatency(
        observedTimestamp: TimeInterval?,
        edgeDate: Date?
    ) -> TimeInterval? {
        guard let observedTimestamp,
            let edgeTimestamp = edgeDate?
                .timeIntervalSinceReferenceDate,
            edgeTimestamp.isFinite
        else {
            return nil
        }
        let latency = observedTimestamp - edgeTimestamp
        guard latency.isFinite else {
            return nil
        }
        return max(0, latency)
    }

    private func windowDuration(
        in snapshot: HLSLivePlaylistSnapshot
    ) -> TimeInterval {
        let complete = snapshot.segments.reduce(0) {
            $0 + $1.duration
        }
        let completeEdge = snapshot.segments.last?.sequenceNumber
        let partial = snapshot.partialSegments.reduce(0) { result, part in
            guard !part.isGap,
                completeEdge.map({
                    part.mediaSequenceNumber > $0
                }) ?? true
            else {
                return result
            }
            return result + part.duration
        }
        let duration = complete + partial
        return duration.isFinite ? max(0, duration) : 0
    }

    private func freshnessStatus(
        estimatedPlaylistAge: TimeInterval?,
        targetDuration: Int?,
        availableWindowDuration: TimeInterval,
        isEnded: Bool,
        thresholds: HLSLiveHealthThresholdPack
    ) -> (isStale: Bool, isCritical: Bool) {
        guard
            !isEnded,
            let estimatedPlaylistAge,
            estimatedPlaylistAge.isFinite,
            estimatedPlaylistAge >= 0,
            let targetDuration,
            targetDuration > 0
        else {
            return (false, false)
        }
        let target = TimeInterval(targetDuration)
        let degradedThreshold =
            target * thresholds.degradedPlaylistAgeMultiplier
        let criticalThreshold = max(
            target * thresholds.criticalPlaylistAgeMultiplier,
            availableWindowDuration
        )
        return (
            estimatedPlaylistAge >= degradedThreshold,
            estimatedPlaylistAge >= criticalThreshold
        )
    }

    private func estimatedPlaylistAge(
        in snapshot: HLSLivePlaylistSnapshot,
        observedTimestamp: TimeInterval?
    ) -> TimeInterval? {
        guard
            let freshness = snapshot.httpFreshness,
            let baseAge = freshness.estimatedPlaylistAge,
            baseAge.isFinite,
            baseAge >= 0
        else {
            return nil
        }
        guard
            let observedTimestamp,
            let measuredTimestamp = finiteTimestamp(
                freshness.measuredAt
            )
        else {
            return baseAge
        }
        let elapsed = max(0, observedTimestamp - measuredTimestamp)
        let age = baseAge + elapsed
        return age.isFinite ? age : nil
    }

    private func compare(
        _ lhs: HLSLiveEdgePosition,
        _ rhs: HLSLiveEdgePosition
    ) -> ComparisonResult {
        if lhs.mediaSequenceNumber != rhs.mediaSequenceNumber {
            return lhs.mediaSequenceNumber < rhs.mediaSequenceNumber
                ? .orderedAscending
                : .orderedDescending
        }
        switch (lhs.partIndex, rhs.partIndex) {
        case (.none, .none):
            return .orderedSame
        case (.none, .some):
            return .orderedDescending
        case (.some, .none):
            return .orderedAscending
        case (.some(let lhs), .some(let rhs)):
            if lhs == rhs {
                return .orderedSame
            }
            return lhs < rhs ? .orderedAscending : .orderedDescending
        }
    }

    private func finiteTimestamp(_ date: Date) -> TimeInterval? {
        let value = date.timeIntervalSinceReferenceDate
        return value.isFinite ? value : nil
    }

    private func finiteDuration(
        from start: TimeInterval?,
        to end: TimeInterval?
    ) -> TimeInterval {
        guard let start, let end else {
            return 0
        }
        let duration = end - start
        return duration.isFinite ? max(0, duration) : 0
    }

    private func incremented(_ value: Int) -> Int {
        let (next, overflow) = value.addingReportingOverflow(1)
        return overflow ? .max : next
    }

    private static let emptySnapshot = HLSLiveHealthSnapshot(
        status: .unknown,
        issues: [],
        observedAt: nil,
        liveEdgePosition: nil,
        reloadMode: nil,
        estimatedLiveEdgeDate: nil,
        estimatedLiveLatency: nil,
        recommendedLiveLatency: nil,
        estimatedPlaylistAge: nil,
        availableWindowDuration: 0,
        stagnantSnapshotCount: 0,
        stagnantDuration: 0,
        deltaRecoveryCount: 0,
        pathwayChangeCount: 0
    )
}
