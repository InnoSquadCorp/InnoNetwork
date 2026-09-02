import Foundation
import InnoNetworkHLS

extension HLSLiveDVRRecordingState {
    mutating func validatePresentation(
        _ snapshot: HLSLivePlaylistSnapshot
    ) throws {
        if !didConfigureRenditions {
            let selection = try HLSLiveDVRRenditionSelector.select(
                from: snapshot,
                pack: configuration.renditions
            )
            selectedVariant = snapshot.selectedVariant
            selectedRenditions = selection.external
            inBandClosedCaptions = selection.inBandClosedCaptions
            renditionStates = selection.external.map {
                HLSLiveDVRRenditionRecordingState(selection: $0)
            }
            initialPathwayID = snapshot.pathwayID
            didConfigureRenditions = true
        } else {
            inBandClosedCaptions =
                HLSLiveDVRRenditionSelector.retainedClosedCaptions(
                    inBandClosedCaptions,
                    in: snapshot,
                    initialPathwayID: initialPathwayID
                )
        }
        try validateTimeline(snapshot, isPrimary: true)

        guard let snapshotContainer = snapshot.playlist.mediaContainer else {
            throw HLSLiveDVRError.unsupportedFeature(
                .unknownMediaContainer
            )
        }
        if let container, container != snapshotContainer {
            throw HLSLiveDVRError.unsupportedFeature(
                .changingInitializationSegment
            )
        }
        container = snapshotContainer

        if snapshot.unsupportedEncryptionMethodForRecording != nil {
            throw HLSLiveDVRError.unsupportedFeature(
                .encryptedMedia
            )
        }

        switch snapshotContainer {
        case .mpegTransportStream:
            guard snapshot.initializationSegments.isEmpty,
                snapshot.segments.allSatisfy({
                    $0.initializationSegment == nil
                })
            else {
                throw HLSLiveDVRError.unsupportedFeature(
                    .changingInitializationSegment
                )
            }
        case .fragmentedMP4:
            if snapshot.segments.isEmpty {
                guard
                    !snapshot.initializationSegments.isEmpty
                        || snapshot.playlist.lowLatency?.preloadHints
                            .contains(where: {
                                $0.type == .initializationMap
                            }) == true
                else {
                    throw HLSLiveDVRError.unsupportedFeature(
                        .missingInitializationSegment
                    )
                }
            } else if !snapshot.segments.allSatisfy({
                $0.initializationSegment != nil
            }) {
                throw HLSLiveDVRError.unsupportedFeature(
                    .missingInitializationSegment
                )
            }
        }
        guard
            Self.matchesOverlappingInitializations(
                segments,
                snapshot: snapshot
            )
        else {
            throw HLSLiveDVRError.unsupportedFeature(
                .changingInitializationSegment
            )
        }
        guard
            Self.matchesOverlappingGaps(
                segments,
                snapshot: snapshot
            )
        else {
            throw HLSLiveDVRError.unsupportedFeature(.gap)
        }
    }

    mutating func candidates(
        in snapshot: HLSLivePlaylistSnapshot
    ) throws -> [HLSLiveSegment] {
        try validateSequence(snapshot.segments)
        if !didObserveInitialSnapshot {
            didObserveInitialSnapshot = true
            if configuration.startPosition
                == .nextCompletedSegment
            {
                lastObservedSequence =
                    snapshot.segments.last?.sequenceNumber
                return []
            }
        }

        let candidates: [HLSLiveSegment]
        if let lastObservedSequence {
            candidates = snapshot.segments.filter {
                $0.sequenceNumber > lastObservedSequence
            }
            if let first = candidates.first {
                let (expected, overflow) =
                    lastObservedSequence.addingReportingOverflow(1)
                guard
                    !overflow,
                    first.sequenceNumber == expected
                else {
                    throw HLSLiveDVRError.liveWindowAdvanced
                }
            }
        } else {
            candidates = snapshot.segments
        }
        return candidates
    }

    func canRetain(_ segment: HLSLiveSegment) -> Bool {
        if configuration.limits.retentionPolicy == .rollingWindow {
            return segment.duration.isFinite
                && segment.duration > 0
                && segment.duration
                    <= configuration.limits.maximumDuration
        }
        guard
            segments.count
                < configuration.limits.maximumSegmentCount
        else {
            return false
        }
        let nextDuration = recordedDuration + segment.duration
        return nextDuration.isFinite
            && nextDuration
                <= configuration.limits.maximumDuration
    }

    func validate(_ segment: HLSLiveSegment) throws {
        guard segment.duration.isFinite, segment.duration > 0 else {
            throw HLSLiveDVRError.transferFailed
        }
        switch container {
        case .mpegTransportStream:
            guard segment.initializationSegment == nil else {
                throw HLSLiveDVRError.unsupportedFeature(
                    .changingInitializationSegment
                )
            }
        case .fragmentedMP4:
            guard segment.initializationSegment != nil else {
                throw HLSLiveDVRError.unsupportedFeature(
                    .missingInitializationSegment
                )
            }
        case nil:
            throw HLSLiveDVRError.unsupportedFeature(
                .unknownMediaContainer
            )
        }
    }

    mutating func retainInitialization(
        _ source: HLSLiveInitializationSegment,
        fileName: String,
        byteCount: Int64,
        contentSHA256: String
    ) throws {
        try addMediaBytes(byteCount)
        try initializationState.retain(
            source,
            fileName: fileName,
            byteCount: byteCount,
            contentSHA256: contentSHA256
        )
        nextResourceIndex += 1
    }

    mutating func removeUnreferencedInitialization(
        _ source: HLSLiveInitializationSegment
    ) throws -> String? {
        let sourceIdentity =
            HLSLiveDVRRecoveryIdentity
            .initializationSegmentIdentity(source)
        guard
            !segments.contains(where: {
                $0.initializationSourceIdentity == sourceIdentity
            }),
            let retained = initializationState.retained(for: source),
            initializationState.records.last == retained,
            mediaByteCount >= retained.byteCount,
            nextResourceIndex > 0
        else {
            return nil
        }
        guard
            let removed = initializationState.removeLast(
                matching: source
            )
        else {
            throw HLSLiveDVRError.storageFailed
        }
        mediaByteCount -= retained.byteCount
        nextResourceIndex -= 1
        return removed.fileName
    }

    mutating func retain(
        _ segment: HLSLiveSegment,
        fileName: String,
        byteCount: Int64,
        contentSHA256: String
    ) throws {
        let nextDuration = recordedDuration + segment.duration
        guard nextDuration.isFinite else {
            throw HLSLiveDVRError.storageFailed
        }
        try addMediaBytes(byteCount)
        try append(
            segment,
            fileName: fileName,
            byteCount: byteCount,
            contentSHA256: contentSHA256,
            nextDuration: nextDuration
        )
        nextResourceIndex += 1
        try applyRollingRetentionAfterPrimarySegment()
    }

    private func validateSequence(
        _ segments: [HLSLiveSegment]
    ) throws {
        var previous: Int64?
        for segment in segments {
            if let previous {
                let (expected, overflow) =
                    previous.addingReportingOverflow(1)
                guard
                    !overflow,
                    segment.sequenceNumber == expected
                else {
                    throw HLSLiveDVRError.liveWindowAdvanced
                }
            }
            previous = segment.sequenceNumber
        }
    }

    func validateTimeline(
        _ snapshot: HLSLivePlaylistSnapshot,
        isPrimary: Bool
    ) throws {
        try validateDateRanges(
            snapshot.dateRanges,
            isPrimary: isPrimary
        )
    }

    func validateDateRanges(
        _ dateRanges: [HLSDateRange],
        isPrimary: Bool
    ) throws {
        if dateRanges.contains(where: { dateRange in
            if let preload = dateRange.preload {
                return configuration.interstitials.policy != .package
                    || dateRange.className
                        != Self.dateRangePreloadClass
                    || preload.targetClass
                        != Self.dateRangeScheduleClass
            }
            guard dateRange.externalResource != nil else {
                return false
            }
            return configuration.interstitials.policy != .package
                || dateRange.className
                    != Self.dateRangeScheduleClass
        }) {
            throw HLSLiveDVRError.unsupportedFeature(
                .externalTimelineResource
            )
        }
        if configuration.interstitials.policy == .disabled,
            dateRanges.contains(where: {
                $0.interstitial != nil
            })
        {
            throw HLSLiveDVRError.unsupportedFeature(
                .externalTimelineResource
            )
        }
        if dateRanges.contains(where: { dateRange in
            let representedNames: Set<String>
            if dateRange.preload != nil {
                representedNames = Self.dateRangePreloadAttributeNames
            } else if dateRange.interstitial != nil {
                representedNames = Self.interstitialAttributeNames
            } else if dateRange.className
                == Self.dateRangeScheduleClass
            {
                representedNames = Self.dateRangeScheduleAttributeNames
            } else {
                representedNames = []
            }
            return !dateRange.extensionAttributeNames.allSatisfy(
                representedNames.contains
            )
        }) {
            throw HLSLiveDVRError.unsupportedFeature(
                .unrepresentableTimelineMetadata
            )
        }
        if !isPrimary, !dateRanges.isEmpty {
            throw HLSLiveDVRError.unsupportedFeature(
                .unrepresentableTimelineMetadata
            )
        }
    }

    private static let interstitialAttributeNames: Set<String> = [
        "X-ASSET-LIST",
        "X-ASSET-URI",
        "X-CONTENT-MAY-VARY",
        "X-PLAYOUT-LIMIT",
        "X-RESTRICT",
        "X-RESUME-OFFSET",
        "X-SKIP-CONTROL-DURATION",
        "X-SKIP-CONTROL-LABEL-ID",
        "X-SKIP-CONTROL-OFFSET",
        "X-TIMELINE-OCCUPIES",
        "X-TIMELINE-STYLE",
    ]

    private static let dateRangeScheduleClass =
        "com.apple.hls.daterange-schedule"

    private static let dateRangePreloadClass =
        "com.apple.hls.preload"

    private static let dateRangeScheduleAttributeNames: Set<String> = [
        "X-URI"
    ]

    private static let dateRangePreloadAttributeNames: Set<String> = [
        "X-DURATION-AT-JOIN",
        "X-TARGET-CLASS",
        "X-TARGET-ID",
        "X-URI",
    ]

    mutating func mergeDateRanges(
        _ updates: [HLSDateRange]
    ) {
        for update in updates {
            if let index = dateRanges.firstIndex(where: {
                $0.id == update.id
            }) {
                dateRanges[index] = update
            } else {
                dateRanges.append(update)
            }
        }
    }

}
