import Foundation

enum HLSPresentationConformanceAnalyzer {
    private static let timelineTolerance: TimeInterval = 0.001

    static func analyze(
        _ nodes: [HLSPresentationGraphNode],
        revision: HLSPresentationConformanceRevision
    ) -> [HLSPresentationDiagnostic] {
        switch revision {
        case .hlsSecondEditionDraft22:
            return draft22Diagnostics(in: nodes)
        }
    }

    private static func draft22Diagnostics(
        in nodes: [HLSPresentationGraphNode]
    ) -> [HLSPresentationDiagnostic] {
        let allIndices = Array(nodes.indices)
        let timelineIndices = nodes.indices.filter {
            !isPureIFrame(nodes[$0])
        }
        guard !allIndices.isEmpty else {
            return []
        }
        var diagnostics: [HLSPresentationDiagnostic] = []
        diagnostics.append(
            contentsOf: targetDurationDiagnostics(
                in: nodes,
                indices: allIndices
            )
        )
        diagnostics.append(
            contentsOf: playlistTypeDiagnostics(
                in: nodes,
                indices: allIndices
            )
        )
        diagnostics.append(
            contentsOf: serverControlDiagnostics(
                in: nodes,
                indices: allIndices
            )
        )
        diagnostics.append(
            contentsOf: dateRangeDiagnostics(
                in: nodes,
                indices: allIndices
            )
        )
        diagnostics.append(
            contentsOf: timelineDiagnostics(
                in: nodes,
                indices: timelineIndices
            )
        )
        return diagnostics
    }

    private static func targetDurationDiagnostics(
        in nodes: [HLSPresentationGraphNode],
        indices: [Int]
    ) -> [HLSPresentationDiagnostic] {
        var diagnostics: [HLSPresentationDiagnostic] = []
        var baseline: (index: Int, value: Int)?
        for index in indices {
            guard let value = nodes[index].document.playlist.targetDuration
            else {
                diagnostics.append(
                    diagnostic(
                        .targetDurationMissing,
                        playlistIndex: index
                    )
                )
                continue
            }
            if isTargetDurationException(nodes[index]) {
                continue
            }
            if let baseline {
                if value != baseline.value {
                    diagnostics.append(
                        diagnostic(
                            .targetDurationMismatch,
                            playlistIndex: index,
                            relatedPlaylistIndex: baseline.index
                        )
                    )
                }
            } else {
                baseline = (index, value)
            }
        }
        return diagnostics
    }

    private static func playlistTypeDiagnostics(
        in nodes: [HLSPresentationGraphNode],
        indices: [Int]
    ) -> [HLSPresentationDiagnostic] {
        guard
            let baselineIndex = indices.first(where: {
                nodes[$0].document.playlist.mediaPlaylistType != nil
            })
        else {
            return []
        }
        let baseline = nodes[baselineIndex].document.playlist.mediaPlaylistType
        return indices.compactMap { index in
            guard index != baselineIndex,
                nodes[index].document.playlist.mediaPlaylistType != baseline
            else {
                return nil
            }
            return diagnostic(
                .playlistTypeMismatch,
                playlistIndex: index,
                relatedPlaylistIndex: baselineIndex
            )
        }
    }

    private static func serverControlDiagnostics(
        in nodes: [HLSPresentationGraphNode],
        indices: [Int]
    ) -> [HLSPresentationDiagnostic] {
        guard
            let baselineIndex = indices.first(where: {
                nodes[$0].document.playlist.lowLatency?.serverControl
                    != nil
            })
        else {
            return []
        }
        let baseline =
            nodes[baselineIndex].document.playlist.lowLatency?.serverControl
        return indices.compactMap { index in
            guard index != baselineIndex,
                nodes[index].document.playlist.lowLatency?.serverControl
                    != baseline
            else {
                return nil
            }
            return diagnostic(
                .serverControlMismatch,
                playlistIndex: index,
                relatedPlaylistIndex: baselineIndex
            )
        }
    }

    private static func dateRangeDiagnostics(
        in nodes: [HLSPresentationGraphNode],
        indices: [Int]
    ) -> [HLSPresentationDiagnostic] {
        let fingerprints = indices.map { index in
            (
                index,
                nodes[index].document.dateRangeFingerprints
            )
        }
        guard
            let baseline = fingerprints.first(where: {
                !$0.1.isEmpty
            })
        else {
            return []
        }
        let baselineIDs = Set(baseline.1.keys)
        var diagnostics: [HLSPresentationDiagnostic] = []
        for (index, values) in fingerprints where !values.isEmpty {
            guard index != baseline.0 else {
                continue
            }
            guard Set(values.keys) == baselineIDs else {
                diagnostics.append(
                    diagnostic(
                        .dateRangeSetMismatch,
                        playlistIndex: index,
                        relatedPlaylistIndex: baseline.0
                    )
                )
                continue
            }
            if values != baseline.1 {
                diagnostics.append(
                    diagnostic(
                        .dateRangeAttributeMismatch,
                        playlistIndex: index,
                        relatedPlaylistIndex: baseline.0
                    )
                )
            }
        }
        return diagnostics
    }

    private static func timelineDiagnostics(
        in nodes: [HLSPresentationGraphNode],
        indices: [Int]
    ) -> [HLSPresentationDiagnostic] {
        let timelines = Dictionary(
            uniqueKeysWithValues: indices.compactMap { index in
                timeline(for: nodes[index]).map { (index, $0) }
            }
        )
        guard !timelines.isEmpty else {
            return []
        }
        var diagnostics: [HLSPresentationDiagnostic] = []

        let datedIndices = indices.filter {
            timelines[$0]?.hasProgramDateTime == true
        }
        if let baseline = datedIndices.first {
            for index in indices where timelines[index] != nil {
                guard timelines[index]?.hasProgramDateTime == true else {
                    diagnostics.append(
                        diagnostic(
                            .programDateTimeMissing,
                            playlistIndex: index,
                            relatedPlaylistIndex: baseline
                        )
                    )
                    continue
                }
                if timelines[index]?.hasConsistentProgramDateTime == false {
                    diagnostics.append(
                        diagnostic(
                            .programDateTimeMappingMismatch,
                            playlistIndex: index
                        )
                    )
                }
            }
        }

        for leftOffset in indices.indices {
            let leftIndex = indices[leftOffset]
            guard let left = timelines[leftIndex] else {
                continue
            }
            for rightOffset in indices.index(after: leftOffset)..<indices.endIndex {
                let rightIndex = indices[rightOffset]
                guard let right = timelines[rightIndex] else {
                    continue
                }
                if left.isVOD, right.isVOD,
                    left.hasProgramDateTime,
                    right.hasProgramDateTime,
                    let leftAnchor = left.programDateTimeAnchor,
                    let rightAnchor = right.programDateTimeAnchor,
                    abs(leftAnchor - rightAnchor) > timelineTolerance
                {
                    diagnostics.append(
                        diagnostic(
                            .programDateTimeMappingMismatch,
                            playlistIndex: rightIndex,
                            relatedPlaylistIndex: leftIndex
                        )
                    )
                }
                guard let comparison = compare(left, right) else {
                    continue
                }
                if !comparison.boundariesMatch {
                    diagnostics.append(
                        diagnostic(
                            .timelineAlignmentMismatch,
                            playlistIndex: rightIndex,
                            relatedPlaylistIndex: leftIndex
                        )
                    )
                    continue
                }
                if !comparison.discontinuitiesMatch {
                    diagnostics.append(
                        diagnostic(
                            .discontinuitySequenceMismatch,
                            playlistIndex: rightIndex,
                            relatedPlaylistIndex: leftIndex
                        )
                    )
                }
            }
        }
        return diagnostics
    }

    private static func timeline(
        for node: HLSPresentationGraphNode
    ) -> Timeline? {
        guard let media = node.document.playlist.media else {
            return nil
        }
        let segments = media.resources.filter { $0.kind == .segment }
        guard !segments.isEmpty else {
            return nil
        }
        var offsets: [TimeInterval] = []
        offsets.reserveCapacity(segments.count)
        var elapsed: TimeInterval = 0
        for segment in segments {
            guard let duration = segment.duration,
                duration.isFinite,
                duration > 0
            else {
                return nil
            }
            offsets.append(elapsed)
            elapsed += duration
            guard elapsed.isFinite else {
                return nil
            }
        }

        let programDates = node.document.playlist.programDateTimes
        var anchors: [TimeInterval] = []
        for value in programDates {
            guard offsets.indices.contains(value.segmentIndex) else {
                continue
            }
            anchors.append(
                value.date.timeIntervalSinceReferenceDate
                    - offsets[value.segmentIndex]
            )
        }
        let anchor = anchors.first
        let hasConsistentProgramDateTime = anchors.dropFirst().allSatisfy {
            guard let anchor else {
                return false
            }
            return abs($0 - anchor) <= timelineTolerance
        }
        let starts = offsets.map { offset in
            (anchor ?? 0) + offset
        }

        var discontinuitySequence = media.discontinuitySequence
        var sequences: [Int64] = []
        sequences.reserveCapacity(segments.count)
        for segment in segments {
            if segment.beginsDiscontinuity {
                let (next, overflow) =
                    discontinuitySequence.addingReportingOverflow(1)
                guard !overflow else {
                    return nil
                }
                discontinuitySequence = next
            }
            sequences.append(discontinuitySequence)
        }
        return Timeline(
            starts: starts,
            end: (anchor ?? 0) + elapsed,
            relativeStarts: offsets,
            duration: elapsed,
            discontinuitySequences: sequences,
            hasProgramDateTime: anchor != nil,
            hasConsistentProgramDateTime:
                hasConsistentProgramDateTime,
            programDateTimeAnchor: anchor,
            isVOD:
                node.document.playlist.mediaPlaylistType
                == .videoOnDemand
        )
    }

    private static func compare(
        _ left: Timeline,
        _ right: Timeline
    ) -> TimelineComparison? {
        let canAlign =
            (left.hasProgramDateTime && right.hasProgramDateTime)
            || (left.isVOD && right.isVOD)
        guard canAlign else {
            return nil
        }
        let usesRelativeTimeline = left.isVOD && right.isVOD
        let leftStarts =
            usesRelativeTimeline ? left.relativeStarts : left.starts
        let rightStarts =
            usesRelativeTimeline ? right.relativeStarts : right.starts
        let leftEnd = usesRelativeTimeline ? left.duration : left.end
        let rightEnd = usesRelativeTimeline ? right.duration : right.end
        let overlapStart = max(
            leftStarts.first ?? 0,
            rightStarts.first ?? 0
        )
        let overlapEnd = min(leftEnd, rightEnd)
        guard overlapEnd - overlapStart > timelineTolerance else {
            return nil
        }
        let leftIndices = leftStarts.indices.filter {
            leftStarts[$0] >= overlapStart - timelineTolerance
                && leftStarts[$0] < overlapEnd - timelineTolerance
        }
        let rightIndices = rightStarts.indices.filter {
            rightStarts[$0] >= overlapStart - timelineTolerance
                && rightStarts[$0] < overlapEnd - timelineTolerance
        }
        guard leftIndices.count == rightIndices.count else {
            return TimelineComparison(
                boundariesMatch: false,
                discontinuitiesMatch: false
            )
        }
        let pairs = Array(zip(leftIndices, rightIndices))
        let boundariesMatch = pairs.allSatisfy { leftIndex, rightIndex in
            abs(leftStarts[leftIndex] - rightStarts[rightIndex])
                <= timelineTolerance
        }
        guard boundariesMatch else {
            return TimelineComparison(
                boundariesMatch: false,
                discontinuitiesMatch: false
            )
        }
        let discontinuitiesMatch = pairs.allSatisfy {
            leftIndex,
            rightIndex in
            left.discontinuitySequences[leftIndex]
                == right.discontinuitySequences[rightIndex]
        }
        return TimelineComparison(
            boundariesMatch: true,
            discontinuitiesMatch: discontinuitiesMatch
        )
    }

    private static func isPureIFrame(
        _ node: HLSPresentationGraphNode
    ) -> Bool {
        node.roles == [.iFrameVariant]
    }

    private static func isTargetDurationException(
        _ node: HLSPresentationGraphNode
    ) -> Bool {
        guard
            node.document.playlist.mediaPlaylistType
                == .videoOnDemand
        else {
            return false
        }
        return node.roles == [.subtitleRendition]
            || node.roles == [.iFrameVariant]
    }

    private static func diagnostic(
        _ code: HLSPresentationDiagnostic.Code,
        playlistIndex: Int,
        relatedPlaylistIndex: Int? = nil
    ) -> HLSPresentationDiagnostic {
        HLSPresentationDiagnostic(
            severity: .error,
            code: code,
            playlistIndex: playlistIndex,
            relatedPlaylistIndex: relatedPlaylistIndex
        )
    }
}

private struct Timeline {
    let starts: [TimeInterval]
    let end: TimeInterval
    let relativeStarts: [TimeInterval]
    let duration: TimeInterval
    let discontinuitySequences: [Int64]
    let hasProgramDateTime: Bool
    let hasConsistentProgramDateTime: Bool
    let programDateTimeAnchor: TimeInterval?
    let isVOD: Bool
}

private struct TimelineComparison {
    let boundariesMatch: Bool
    let discontinuitiesMatch: Bool
}
