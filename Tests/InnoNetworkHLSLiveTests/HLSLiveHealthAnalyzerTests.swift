import Foundation
import InnoNetworkHLS
import Testing

@testable import InnoNetworkHLSLive

@Suite("HLS live health")
struct HLSLiveHealthAnalyzerTests {
    @Test("health thresholds remain finite, ordered, and bounded")
    func normalizesThresholds() {
        let thresholds = HLSLiveHealthThresholdPack(
            degradedStagnantSnapshotCount: -1,
            criticalStagnantSnapshotCount: -1,
            degradedDeltaRecoveryCount: .max,
            degradedPathwayChangeCount: .max,
            degradedLatencyDrift: .infinity,
            criticalLatencyDrift: -.infinity
        )

        #expect(thresholds.degradedStagnantSnapshotCount == 1)
        #expect(thresholds.criticalStagnantSnapshotCount == 1)
        #expect(thresholds.degradedDeltaRecoveryCount == 10_000)
        #expect(thresholds.degradedPathwayChangeCount == 10_000)
        #expect(thresholds.degradedLatencyDrift == 3)
        #expect(thresholds.criticalLatencyDrift == 15)
    }

    @Test("partial edge estimates latency from program time and hold-back")
    func estimatesPartialEdgeLatency() throws {
        let baseDate = Date(timeIntervalSinceReferenceDate: 1_000)
        let snapshot = try snapshot(
            sequenceNumber: 20,
            duration: 4,
            programDateTime: baseDate,
            partialDurations: [1, 1],
            serverControl:
                "CAN-BLOCK-RELOAD=YES,HOLD-BACK=12,PART-HOLD-BACK=2"
        )
        var analyzer = HLSLiveHealthAnalyzer()

        let health = analyzer.ingest(
            snapshot,
            observedAt: baseDate.addingTimeInterval(8)
        )

        #expect(health.status == .healthy)
        #expect(health.issues.isEmpty)
        #expect(
            health.liveEdgePosition
                == HLSLiveEdgePosition(
                    mediaSequenceNumber: 21,
                    partIndex: 1
                )
        )
        #expect(
            health.estimatedLiveEdgeDate
                == baseDate.addingTimeInterval(6)
        )
        #expect(health.estimatedLiveLatency == 2)
        #expect(health.recommendedLiveLatency == 2)
        #expect(health.availableWindowDuration == 6)
    }

    @Test("stagnation degrades then becomes a live-window risk")
    func detectsStagnationAndWindowRisk() throws {
        let snapshot = try snapshot(
            sequenceNumber: 10,
            duration: 4
        )
        let baseDate = Date(timeIntervalSinceReferenceDate: 2_000)
        var analyzer = HLSLiveHealthAnalyzer(
            configuration: .advanced(
                thresholds: HLSLiveHealthThresholdPack(
                    degradedStagnantSnapshotCount: 2,
                    criticalStagnantSnapshotCount: 4
                )
            )
        )

        _ = analyzer.ingest(snapshot, observedAt: baseDate)
        _ = analyzer.ingest(
            snapshot,
            observedAt: baseDate.addingTimeInterval(1)
        )
        let degraded = analyzer.ingest(
            snapshot,
            observedAt: baseDate.addingTimeInterval(2)
        )
        _ = analyzer.ingest(
            snapshot,
            observedAt: baseDate.addingTimeInterval(3)
        )
        let critical = analyzer.ingest(
            snapshot,
            observedAt: baseDate.addingTimeInterval(4)
        )

        #expect(degraded.status == .degraded)
        #expect(degraded.issues == [.stagnantLiveEdge])
        #expect(degraded.stagnantSnapshotCount == 2)
        #expect(degraded.stagnantDuration == 2)
        #expect(critical.status == .critical)
        #expect(
            critical.issues
                == [.stagnantLiveEdge, .liveWindowAtRisk]
        )
        #expect(critical.stagnantSnapshotCount == 4)
        #expect(critical.stagnantDuration == 4)
    }

    @Test("reload recovery and pathway changes accumulate without I/O")
    func accumulatesRecoveryAndPathwaySignals() throws {
        let base = try snapshot(
            sequenceNumber: 30,
            duration: 4,
            pathwayID: "A"
        )
        let firstRecovery = try snapshot(
            sequenceNumber: 30,
            duration: 4,
            pathwayID: "B",
            reloadMode: .fullReloadRecovery
        )
        let secondRecovery = try snapshot(
            sequenceNumber: 30,
            duration: 4,
            pathwayID: "C",
            reloadMode: .fullReloadRecovery
        )
        let observedAt = Date(timeIntervalSinceReferenceDate: 3_000)
        var analyzer = HLSLiveHealthAnalyzer()

        _ = analyzer.ingest(base, observedAt: observedAt)
        _ = analyzer.ingest(
            firstRecovery,
            observedAt: observedAt.addingTimeInterval(1)
        )
        let health = analyzer.ingest(
            secondRecovery,
            observedAt: observedAt.addingTimeInterval(2)
        )

        #expect(health.status == .degraded)
        #expect(
            health.issues
                == [.repeatedDeltaRecovery, .pathwayInstability]
        )
        #expect(health.deltaRecoveryCount == 2)
        #expect(health.pathwayChangeCount == 2)
    }

    @Test("a regressed live edge is immediately critical")
    func detectsLiveEdgeRegression() throws {
        let newer = try snapshot(sequenceNumber: 10, duration: 4)
        let older = try snapshot(sequenceNumber: 9, duration: 4)
        let observedAt = Date(timeIntervalSinceReferenceDate: 4_000)
        var analyzer = HLSLiveHealthAnalyzer()

        _ = analyzer.ingest(newer, observedAt: observedAt)
        let health = analyzer.ingest(
            older,
            observedAt: observedAt.addingTimeInterval(1)
        )

        #expect(health.status == .critical)
        #expect(health.issues == [.liveEdgeRegression])
        #expect(health.stagnantSnapshotCount == 1)
    }

    @Test("out-of-order observation time cannot inflate stagnation")
    func keepsObservationTimeMonotonic() throws {
        let baseDate = Date(timeIntervalSinceReferenceDate: 5_000)
        let first = try snapshot(
            sequenceNumber: 1,
            duration: 4,
            programDateTime: baseDate
        )
        let second = try snapshot(
            sequenceNumber: 2,
            duration: 4,
            programDateTime: baseDate.addingTimeInterval(4)
        )
        var analyzer = HLSLiveHealthAnalyzer()

        _ = analyzer.ingest(
            first,
            observedAt: baseDate.addingTimeInterval(10)
        )
        let outOfOrder = analyzer.ingest(
            second,
            observedAt: baseDate.addingTimeInterval(5)
        )
        let health = analyzer.ingest(
            second,
            observedAt: baseDate.addingTimeInterval(12)
        )

        #expect(outOfOrder.observedAt == baseDate.addingTimeInterval(10))
        #expect(outOfOrder.estimatedLiveLatency == 2)
        #expect(health.observedAt == baseDate.addingTimeInterval(12))
        #expect(health.estimatedLiveLatency == 4)
        #expect(health.stagnantDuration == 2)
    }

    @Test("reset returns an analyzer to unknown health")
    func resetsAnalysis() throws {
        let snapshot = try snapshot(sequenceNumber: 1, duration: 4)
        var analyzer = HLSLiveHealthAnalyzer()
        _ = analyzer.ingest(
            snapshot,
            observedAt: Date(timeIntervalSinceReferenceDate: 6_000)
        )

        analyzer.reset()

        #expect(analyzer.snapshot.status == .unknown)
        #expect(analyzer.snapshot.issues.isEmpty)
        #expect(analyzer.snapshot.observedAt == nil)
    }

    private func snapshot(
        sequenceNumber: Int64,
        duration: TimeInterval,
        programDateTime: Date? = nil,
        partialDurations: [TimeInterval] = [],
        serverControl: String? = nil,
        pathwayID: String? = nil,
        reloadMode: HLSLiveReloadMode = .initial
    ) throws -> HLSLivePlaylistSnapshot {
        let sourceURL = try #require(
            URL(string: "https://media.example/health.m3u8")
        )
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:9",
            "#EXT-X-TARGETDURATION:4",
            "#EXT-X-MEDIA-SEQUENCE:\(sequenceNumber)",
        ]
        if let serverControl {
            lines.append("#EXT-X-SERVER-CONTROL:\(serverControl)")
            lines.append("#EXT-X-PART-INF:PART-TARGET=1")
        }
        lines.append(contentsOf: ["#EXTINF:\(duration),", "segment.ts"])
        let playlist = try PlaylistResolver().resolve(
            lines.joined(separator: "\n"),
            relativeTo: sourceURL
        )
        let (partialSequence, overflow) =
            sequenceNumber.addingReportingOverflow(1)
        let partialSegments: [HLSLivePartialSegment]
        if overflow {
            partialSegments = []
        } else {
            partialSegments = partialDurations.enumerated().map {
                index, partDuration in
                HLSLivePartialSegment(
                    mediaSequenceNumber: partialSequence,
                    partIndex: index,
                    duration: partDuration,
                    url: sourceURL,
                    byteRange: nil,
                    isIndependent: index == 0,
                    isGap: false
                )
            }
        }
        return HLSLivePlaylistSnapshot(
            playlist: playlist,
            segments: [
                HLSLiveSegment(
                    sequenceNumber: sequenceNumber,
                    duration: duration,
                    url: sourceURL,
                    byteRange: nil,
                    beginsDiscontinuity: false,
                    isGap: false,
                    programDateTime: programDateTime
                )
            ],
            partialSegments: partialSegments,
            dateRanges: [],
            pathwayID: pathwayID,
            generation: 0,
            reloadMode: reloadMode,
            isDeltaUpdate: false,
            isEnded: false
        )
    }
}
