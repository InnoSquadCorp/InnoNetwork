import Foundation
import Testing

@testable import InnoNetworkHLSAVFoundation

@Suite("HLS playback health analyzer")
struct HLSPlaybackHealthAnalyzerTests {
    @Test("configuration normalizes unsafe thresholds and retention")
    func normalizesConfiguration() {
        let thresholds = HLSPlaybackHealthThresholdPack(
            observationWindow: .nan,
            slowStartupDuration: -.infinity,
            slowMediaTransferDuration: .infinity,
            criticalStallCount: 0,
            degradedRecoverableErrorCount: -1,
            criticalMediaRequestFailureCount: .max,
            degradedVariantSwitchCount: 0
        )
        let configuration = HLSPlaybackHealthConfiguration.advanced(
            thresholds: thresholds,
            maximumRetainedEventCount: 0
        )

        #expect(thresholds.observationWindow == 60)
        #expect(thresholds.slowStartupDuration == 5)
        #expect(thresholds.slowMediaTransferDuration == 2)
        #expect(thresholds.criticalStallCount == 1)
        #expect(thresholds.degradedRecoverableErrorCount == 1)
        #expect(
            thresholds.criticalMediaRequestFailureCount == 10_000
        )
        #expect(thresholds.degradedVariantSwitchCount == 1)
        #expect(configuration.maximumRetainedEventCount == 1)
    }

    @Test("an empty analyzer is unknown and neutral events become healthy")
    func reportsUnknownThenHealthy() {
        var analyzer = HLSPlaybackHealthAnalyzer()

        #expect(analyzer.snapshot.status == .unknown)
        let snapshot = analyzer.ingest(
            .rateChanged(
                context(at: 0),
                previousRate: 0,
                rate: 1
            )
        )

        #expect(snapshot.status == .healthy)
        #expect(snapshot.issues.isEmpty)
        #expect(snapshot.retainedEventCount == 1)
    }

    @Test("slow startup remains a session-level degraded signal")
    func detectsSlowStartup() {
        var analyzer = HLSPlaybackHealthAnalyzer(
            configuration: .advanced(
                thresholds: HLSPlaybackHealthThresholdPack(
                    observationWindow: 10,
                    slowStartupDuration: 1
                )
            )
        )

        _ = analyzer.ingest(
            .likelyToKeepUp(
                context(at: 0),
                isInitial: true,
                timeTaken: 2
            )
        )
        let snapshot = analyzer.ingest(
            .rateChanged(
                context(at: 20),
                previousRate: 0,
                rate: 1
            )
        )

        #expect(snapshot.status == .degraded)
        #expect(snapshot.issues == [.slowStartup])
        #expect(snapshot.initialStartupDuration == 2)
        #expect(snapshot.retainedEventCount == 1)
    }

    @Test("rolling stalls become critical and age out")
    func evaluatesRollingStalls() {
        var analyzer = HLSPlaybackHealthAnalyzer(
            configuration: .advanced(
                thresholds: HLSPlaybackHealthThresholdPack(
                    observationWindow: 10,
                    criticalStallCount: 3
                )
            )
        )
        for second in 0...2 {
            _ = analyzer.ingest(.stalled(context(at: second)))
        }

        #expect(analyzer.snapshot.status == .critical)
        #expect(analyzer.snapshot.stallCount == 3)
        #expect(analyzer.snapshot.issues == [.playbackStalls])

        let recovered = analyzer.ingest(
            .rateChanged(
                context(at: 20),
                previousRate: 0,
                rate: 1
            )
        )
        #expect(recovered.status == .healthy)
        #expect(recovered.stallCount == 0)
    }

    @Test("playback summaries reconcile dropped aggregate events")
    func reconcilesPlaybackSummary() {
        var analyzer = HLSPlaybackHealthAnalyzer(
            configuration: .advanced(
                thresholds: HLSPlaybackHealthThresholdPack(
                    degradedRecoverableErrorCount: 2,
                    degradedVariantSwitchCount: 3
                )
            )
        )
        let snapshot = analyzer.ingest(
            .playbackSummary(
                context(at: 1),
                summary: summary(
                    recoverableErrors: 2,
                    stalls: 1,
                    variantSwitches: 3
                )
            )
        )

        #expect(snapshot.status == .degraded)
        #expect(snapshot.stallCount == 1)
        #expect(snapshot.recoverableErrorCount == 2)
        #expect(snapshot.variantSwitchCount == 3)
        #expect(
            snapshot.issues
                == [
                    .playbackStalls,
                    .repeatedRecoverableErrors,
                    .variantInstability,
                ]
        )
    }

    @Test("failed media requests become critical at their threshold")
    func evaluatesMediaRequestFailures() {
        var analyzer = HLSPlaybackHealthAnalyzer(
            configuration: .advanced(
                thresholds: HLSPlaybackHealthThresholdPack(
                    slowMediaTransferDuration: 1,
                    criticalMediaRequestFailureCount: 2
                )
            )
        )
        let failedTransfer = transfer(
            duration: 2,
            hadError: true,
            didRecover: false
        )

        _ = analyzer.ingest(
            .mediaResourceRequest(
                context(at: 0),
                transfer: failedTransfer
            )
        )
        let snapshot = analyzer.ingest(
            .contentKeyRequest(
                context(at: 1),
                mediaType: .video,
                isClientInitiated: false,
                transfer: failedTransfer
            )
        )

        #expect(snapshot.status == .critical)
        #expect(snapshot.mediaRequestFailureCount == 2)
        #expect(snapshot.slowMediaTransferCount == 2)
        #expect(
            snapshot.issues
                == [
                    .mediaRequestFailures,
                    .slowMediaTransfers,
                ]
        )
    }

    @Test("cached transfers do not trigger network slowness")
    func ignoresCachedTransferDuration() {
        var analyzer = HLSPlaybackHealthAnalyzer(
            configuration: .advanced(
                thresholds: HLSPlaybackHealthThresholdPack(
                    slowMediaTransferDuration: 1
                )
            )
        )

        let snapshot = analyzer.ingest(
            .playlistRequest(
                context(at: 0),
                mediaType: .video,
                isMultivariant: false,
                transfer: transfer(
                    duration: 30,
                    wasReadFromCache: true
                )
            )
        )

        #expect(snapshot.status == .healthy)
        #expect(snapshot.slowMediaTransferCount == 0)
    }

    @Test("whole-request latency contributes to slow transfers")
    func usesLongestTransferDuration() {
        var analyzer = HLSPlaybackHealthAnalyzer(
            configuration: .advanced(
                thresholds: HLSPlaybackHealthThresholdPack(
                    slowMediaTransferDuration: 1
                )
            )
        )
        let transfer = HLSPlaybackTransferMetric(
            requestDuration: 2,
            responseDuration: 0.25,
            byteCount: 1_024,
            wasReadFromCache: false,
            hadError: false,
            didRecover: false
        )

        let snapshot = analyzer.ingest(
            .mediaResourceRequest(
                context(at: 0),
                transfer: transfer
            )
        )

        #expect(snapshot.status == .degraded)
        #expect(snapshot.slowMediaTransferCount == 1)
        #expect(snapshot.issues == [.slowMediaTransfers])
    }

    @Test("recovered transfer errors contribute to degraded health")
    func countsRecoveredTransferErrors() {
        var analyzer = HLSPlaybackHealthAnalyzer(
            configuration: .advanced(
                thresholds: HLSPlaybackHealthThresholdPack(
                    degradedRecoverableErrorCount: 1
                )
            )
        )

        let snapshot = analyzer.ingest(
            .mediaSegmentRequest(
                context(at: 0),
                mediaType: .video,
                isMapSegment: false,
                segmentDuration: 4,
                transfer: transfer(
                    duration: 0.5,
                    hadError: true,
                    didRecover: true
                )
            )
        )

        #expect(snapshot.status == .degraded)
        #expect(snapshot.recoverableErrorCount == 1)
        #expect(snapshot.mediaRequestFailureCount == 0)
        #expect(snapshot.issues == [.repeatedRecoverableErrors])
    }

    @Test("variant outcomes preserve stable diagnostic ordering")
    func evaluatesVariantSwitches() {
        var analyzer = HLSPlaybackHealthAnalyzer(
            configuration: .advanced(
                thresholds: HLSPlaybackHealthThresholdPack(
                    degradedVariantSwitchCount: 2
                )
            )
        )
        _ = analyzer.ingest(
            .variantSwitch(
                context(at: 0),
                phase: .completed(didSucceed: true)
            )
        )
        let snapshot = analyzer.ingest(
            .variantSwitch(
                context(at: 1),
                phase: .completed(didSucceed: false)
            )
        )

        #expect(snapshot.status == .degraded)
        #expect(snapshot.variantSwitchCount == 2)
        #expect(snapshot.variantSwitchFailureCount == 1)
        #expect(
            snapshot.issues
                == [
                    .variantInstability,
                    .variantSwitchFailures,
                ]
        )
    }

    @Test("terminal errors persist until explicit reset")
    func retainsTerminalErrorsUntilReset() {
        var analyzer = HLSPlaybackHealthAnalyzer(
            configuration: .advanced(
                thresholds: HLSPlaybackHealthThresholdPack(
                    observationWindow: 1
                )
            )
        )
        _ = analyzer.ingest(
            .error(context(at: 0), didRecover: false)
        )
        let snapshot = analyzer.ingest(
            .rateChanged(
                context(at: 10),
                previousRate: 0,
                rate: 1
            )
        )

        #expect(snapshot.status == .critical)
        #expect(snapshot.issues == [.terminalPlaybackError])

        analyzer.reset()
        #expect(analyzer.snapshot.status == .unknown)
        #expect(analyzer.snapshot.issues.isEmpty)
    }

    @Test("retained events remain memory bounded")
    func boundsRetainedEvents() {
        var analyzer = HLSPlaybackHealthAnalyzer(
            configuration: .advanced(
                maximumRetainedEventCount: 2
            )
        )
        for second in 0...2 {
            _ = analyzer.ingest(
                .rateChanged(
                    context(at: second),
                    previousRate: 0,
                    rate: 1
                )
            )
        }

        #expect(analyzer.snapshot.retainedEventCount == 2)
        #expect(
            analyzer.snapshot.observedAt
                == context(at: 2).date
        )
    }

    private func context(
        at seconds: Int
    ) -> HLSPlaybackMetricContext {
        HLSPlaybackMetricContext(
            date: Date(
                timeIntervalSinceReferenceDate:
                    TimeInterval(seconds)
            ),
            mediaTime: TimeInterval(seconds)
        )
    }

    private func transfer(
        duration: TimeInterval,
        wasReadFromCache: Bool = false,
        hadError: Bool = false,
        didRecover: Bool = false
    ) -> HLSPlaybackTransferMetric {
        HLSPlaybackTransferMetric(
            requestDuration: duration,
            responseDuration: duration,
            byteCount: 1_024,
            wasReadFromCache: wasReadFromCache,
            hadError: hadError,
            didRecover: didRecover
        )
    }

    private func summary(
        recoverableErrors: Int,
        stalls: Int,
        variantSwitches: Int
    ) -> HLSPlaybackMetricSummary {
        HLSPlaybackMetricSummary(
            recoverableErrorCount: recoverableErrors,
            stallCount: stalls,
            variantSwitchCount: variantSwitches,
            playbackDuration: 30,
            mediaResourceRequestCount: 10,
            stallRecoveryDuration: 1,
            initialStartupDuration: 1,
            timeWeightedAverageBitrate: 1_000_000,
            timeWeightedPeakBitrate: 2_000_000,
            hadError: false
        )
    }
}
