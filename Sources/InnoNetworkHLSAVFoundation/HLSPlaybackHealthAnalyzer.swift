import Foundation

/// Reduces value-redacted playback metrics into deterministic health
/// snapshots.
///
/// The analyzer performs no observation or I/O. Give each playback session its
/// own mutable analyzer and pass it events from ``HLSPlaybackMetrics/events()``.
public struct HLSPlaybackHealthAnalyzer: Sendable {
    private let configuration: HLSPlaybackHealthConfiguration
    private var samples: [HLSPlaybackHealthSample] = []
    private var newestTimestamp: TimeInterval?
    private var initialStartupDuration: TimeInterval?
    private var hasTerminalPlaybackError = false

    /// Creates an empty playback-health analysis session.
    public init(
        configuration: HLSPlaybackHealthConfiguration = .safeDefaults()
    ) {
        self.configuration = configuration
    }

    /// The current health snapshot without mutating analysis state.
    public var snapshot: HLSPlaybackHealthSnapshot {
        makeSnapshot()
    }

    /// Ingests one delivered metric and returns the updated health snapshot.
    ///
    /// Analysis reflects only delivered events. If the upstream metrics stream
    /// drops buffered events, the next playback summary can reconcile its
    /// aggregate stall, recoverable-error, and variant-switch counts.
    @discardableResult
    public mutating func ingest(
        _ event: HLSPlaybackMetricEvent
    ) -> HLSPlaybackHealthSnapshot {
        let signal = signal(for: event)
        let timestamp = finiteTimestamp(
            signal.context.date
        )
        if let timestamp {
            newestTimestamp = max(
                newestTimestamp ?? timestamp,
                timestamp
            )
        }
        if let startupDuration = signal.initialStartupDuration {
            self.initialStartupDuration = startupDuration
        }
        if signal.hasTerminalPlaybackError {
            hasTerminalPlaybackError = true
        }
        samples.append(
            HLSPlaybackHealthSample(
                timestamp: timestamp,
                stallCount: signal.stallCount,
                recoverableErrorCount:
                    signal.recoverableErrorCount,
                mediaRequestFailureCount:
                    signal.mediaRequestFailureCount,
                slowMediaTransferCount:
                    signal.slowMediaTransferCount,
                variantSwitchCount:
                    signal.variantSwitchCount,
                variantSwitchFailureCount:
                    signal.variantSwitchFailureCount,
                summaryStallCount:
                    signal.summaryStallCount,
                summaryRecoverableErrorCount:
                    signal.summaryRecoverableErrorCount,
                summaryVariantSwitchCount:
                    signal.summaryVariantSwitchCount
            )
        )
        pruneSamples()
        return makeSnapshot()
    }

    /// Removes all events and session-level health signals.
    public mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        newestTimestamp = nil
        initialStartupDuration = nil
        hasTerminalPlaybackError = false
    }

    private mutating func pruneSamples() {
        if let newestTimestamp {
            let cutoff =
                newestTimestamp
                - configuration.thresholds.observationWindow
            samples.removeAll {
                guard let timestamp = $0.timestamp else {
                    return true
                }
                return timestamp < cutoff
            }
        }
        let overflow =
            samples.count
            - configuration.maximumRetainedEventCount
        if overflow > 0 {
            samples.removeFirst(overflow)
        }
    }

    private func makeSnapshot() -> HLSPlaybackHealthSnapshot {
        guard !samples.isEmpty else {
            return HLSPlaybackHealthSnapshot(
                status: .unknown,
                issues: [],
                observedAt: newestTimestamp.map {
                    Date(timeIntervalSinceReferenceDate: $0)
                },
                retainedEventCount: 0,
                stallCount: 0,
                recoverableErrorCount: 0,
                mediaRequestFailureCount: 0,
                slowMediaTransferCount: 0,
                variantSwitchCount: 0,
                variantSwitchFailureCount: 0,
                initialStartupDuration: initialStartupDuration
            )
        }

        let aggregate = HLSPlaybackHealthAggregate(
            samples: samples
        )
        let thresholds = configuration.thresholds
        var issues: [HLSPlaybackHealthIssue] = []
        if let initialStartupDuration,
            initialStartupDuration
                > thresholds.slowStartupDuration
        {
            issues.append(.slowStartup)
        }
        if aggregate.stallCount > 0 {
            issues.append(.playbackStalls)
        }
        if aggregate.recoverableErrorCount
            >= thresholds.degradedRecoverableErrorCount
        {
            issues.append(.repeatedRecoverableErrors)
        }
        if aggregate.mediaRequestFailureCount > 0 {
            issues.append(.mediaRequestFailures)
        }
        if aggregate.slowMediaTransferCount > 0 {
            issues.append(.slowMediaTransfers)
        }
        if aggregate.variantSwitchCount
            >= thresholds.degradedVariantSwitchCount
        {
            issues.append(.variantInstability)
        }
        if aggregate.variantSwitchFailureCount > 0 {
            issues.append(.variantSwitchFailures)
        }
        if hasTerminalPlaybackError {
            issues.append(.terminalPlaybackError)
        }

        let isCritical =
            hasTerminalPlaybackError
            || aggregate.stallCount
                >= thresholds.criticalStallCount
            || aggregate.mediaRequestFailureCount
                >= thresholds
                .criticalMediaRequestFailureCount
        let status: HLSPlaybackHealthStatus
        if isCritical {
            status = .critical
        } else if issues.isEmpty {
            status = .healthy
        } else {
            status = .degraded
        }
        return HLSPlaybackHealthSnapshot(
            status: status,
            issues: issues,
            observedAt: newestTimestamp.map {
                Date(timeIntervalSinceReferenceDate: $0)
            },
            retainedEventCount: samples.count,
            stallCount: aggregate.stallCount,
            recoverableErrorCount:
                aggregate.recoverableErrorCount,
            mediaRequestFailureCount:
                aggregate.mediaRequestFailureCount,
            slowMediaTransferCount:
                aggregate.slowMediaTransferCount,
            variantSwitchCount:
                aggregate.variantSwitchCount,
            variantSwitchFailureCount:
                aggregate.variantSwitchFailureCount,
            initialStartupDuration: initialStartupDuration
        )
    }

    private func signal(
        for event: HLSPlaybackMetricEvent
    ) -> HLSPlaybackHealthSignal {
        switch event {
        case .error(let context, let didRecover):
            return HLSPlaybackHealthSignal(
                context: context,
                recoverableErrorCount: didRecover ? 1 : 0,
                hasTerminalPlaybackError: !didRecover
            )
        case .mediaResourceRequest(
            let context,
            let transfer
        ):
            return signal(
                context: context,
                transfer: transfer
            )
        case .playlistRequest(
            let context,
            _,
            _,
            let transfer
        ),
            .mediaSegmentRequest(
                let context,
                _,
                _,
                _,
                let transfer
            ),
            .contentKeyRequest(
                let context,
                _,
                _,
                let transfer
            ):
            return signal(
                context: context,
                transfer: transfer
            )
        case .likelyToKeepUp(
            let context,
            let isInitial,
            let timeTaken
        ):
            return HLSPlaybackHealthSignal(
                context: context,
                initialStartupDuration:
                    isInitial ? finiteNonnegative(timeTaken) : nil
            )
        case .stalled(let context):
            return HLSPlaybackHealthSignal(
                context: context,
                stallCount: 1
            )
        case .variantSwitch(
            let context,
            let phase
        ):
            switch phase {
            case .started:
                return HLSPlaybackHealthSignal(context: context)
            case .completed(let didSucceed):
                return HLSPlaybackHealthSignal(
                    context: context,
                    variantSwitchCount: 1,
                    variantSwitchFailureCount:
                        didSucceed ? 0 : 1
                )
            }
        case .playbackSummary(
            let context,
            let summary
        ):
            return HLSPlaybackHealthSignal(
                context: context,
                initialStartupDuration:
                    finiteNonnegative(
                        summary.initialStartupDuration
                    ),
                hasTerminalPlaybackError: summary.hadError,
                summaryStallCount: max(0, summary.stallCount),
                summaryRecoverableErrorCount:
                    max(0, summary.recoverableErrorCount),
                summaryVariantSwitchCount:
                    max(0, summary.variantSwitchCount)
            )
        case .rateChanged(let context, _, _),
            .seekStarted(let context),
            .seekCompleted(let context, _),
            .playbackModeChanged(let context, _),
            .unclassified(let context):
            return HLSPlaybackHealthSignal(context: context)
        }
    }

    private func signal(
        context: HLSPlaybackMetricContext,
        transfer: HLSPlaybackTransferMetric?
    ) -> HLSPlaybackHealthSignal {
        guard let transfer else {
            return HLSPlaybackHealthSignal(context: context)
        }
        let durations = [
            finiteNonnegative(transfer.requestDuration),
            finiteNonnegative(transfer.responseDuration),
        ].compactMap { $0 }
        let duration = durations.max()
        return HLSPlaybackHealthSignal(
            context: context,
            recoverableErrorCount:
                transfer.hadError && transfer.didRecover ? 1 : 0,
            mediaRequestFailureCount:
                transfer.hadError && !transfer.didRecover ? 1 : 0,
            slowMediaTransferCount:
                !transfer.wasReadFromCache
                && duration.map {
                    $0
                        > configuration.thresholds
                        .slowMediaTransferDuration
                } == true
                ? 1 : 0
        )
    }

    private func finiteTimestamp(_ date: Date) -> TimeInterval? {
        let value = date.timeIntervalSinceReferenceDate
        return value.isFinite ? value : nil
    }

    private func finiteNonnegative(
        _ value: TimeInterval?
    ) -> TimeInterval? {
        guard let value, value.isFinite, value >= 0 else {
            return nil
        }
        return value
    }
}

private struct HLSPlaybackHealthSignal {
    let context: HLSPlaybackMetricContext
    var initialStartupDuration: TimeInterval?
    var stallCount: Int
    var recoverableErrorCount: Int
    var mediaRequestFailureCount: Int
    var slowMediaTransferCount: Int
    var variantSwitchCount: Int
    var variantSwitchFailureCount: Int
    var hasTerminalPlaybackError: Bool
    var summaryStallCount: Int
    var summaryRecoverableErrorCount: Int
    var summaryVariantSwitchCount: Int

    init(
        context: HLSPlaybackMetricContext,
        initialStartupDuration: TimeInterval? = nil,
        stallCount: Int = 0,
        recoverableErrorCount: Int = 0,
        mediaRequestFailureCount: Int = 0,
        slowMediaTransferCount: Int = 0,
        variantSwitchCount: Int = 0,
        variantSwitchFailureCount: Int = 0,
        hasTerminalPlaybackError: Bool = false,
        summaryStallCount: Int = 0,
        summaryRecoverableErrorCount: Int = 0,
        summaryVariantSwitchCount: Int = 0
    ) {
        self.context = context
        self.initialStartupDuration = initialStartupDuration
        self.stallCount = stallCount
        self.recoverableErrorCount = recoverableErrorCount
        self.mediaRequestFailureCount = mediaRequestFailureCount
        self.slowMediaTransferCount = slowMediaTransferCount
        self.variantSwitchCount = variantSwitchCount
        self.variantSwitchFailureCount = variantSwitchFailureCount
        self.hasTerminalPlaybackError = hasTerminalPlaybackError
        self.summaryStallCount = summaryStallCount
        self.summaryRecoverableErrorCount =
            summaryRecoverableErrorCount
        self.summaryVariantSwitchCount = summaryVariantSwitchCount
    }
}

private struct HLSPlaybackHealthSample {
    let timestamp: TimeInterval?
    let stallCount: Int
    let recoverableErrorCount: Int
    let mediaRequestFailureCount: Int
    let slowMediaTransferCount: Int
    let variantSwitchCount: Int
    let variantSwitchFailureCount: Int
    let summaryStallCount: Int
    let summaryRecoverableErrorCount: Int
    let summaryVariantSwitchCount: Int
}

private struct HLSPlaybackHealthAggregate {
    let stallCount: Int
    let recoverableErrorCount: Int
    let mediaRequestFailureCount: Int
    let slowMediaTransferCount: Int
    let variantSwitchCount: Int
    let variantSwitchFailureCount: Int

    init(samples: [HLSPlaybackHealthSample]) {
        var stallCount = 0
        var recoverableErrorCount = 0
        var mediaRequestFailureCount = 0
        var slowMediaTransferCount = 0
        var variantSwitchCount = 0
        var variantSwitchFailureCount = 0
        var summaryStallCount = 0
        var summaryRecoverableErrorCount = 0
        var summaryVariantSwitchCount = 0
        for sample in samples {
            stallCount += sample.stallCount
            recoverableErrorCount += sample.recoverableErrorCount
            mediaRequestFailureCount +=
                sample.mediaRequestFailureCount
            slowMediaTransferCount +=
                sample.slowMediaTransferCount
            variantSwitchCount += sample.variantSwitchCount
            variantSwitchFailureCount +=
                sample.variantSwitchFailureCount
            summaryStallCount = max(
                summaryStallCount,
                sample.summaryStallCount
            )
            summaryRecoverableErrorCount = max(
                summaryRecoverableErrorCount,
                sample.summaryRecoverableErrorCount
            )
            summaryVariantSwitchCount = max(
                summaryVariantSwitchCount,
                sample.summaryVariantSwitchCount
            )
        }
        self.stallCount = max(
            stallCount,
            summaryStallCount
        )
        self.recoverableErrorCount = max(
            recoverableErrorCount,
            summaryRecoverableErrorCount
        )
        self.mediaRequestFailureCount =
            mediaRequestFailureCount
        self.slowMediaTransferCount = slowMediaTransferCount
        self.variantSwitchCount = max(
            variantSwitchCount,
            summaryVariantSwitchCount
        )
        self.variantSwitchFailureCount =
            variantSwitchFailureCount
    }
}
