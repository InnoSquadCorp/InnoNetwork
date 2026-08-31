import Foundation

package enum HLSLiveBridgeError: Error {
    case mediaPlaylistRequired
}

package struct HLSLiveAES128EncryptionRecord: Equatable, Sendable {
    package let keyURL: URL
    package let initializationVector: Data
}

package struct HLSLiveSegmentRecord: Equatable, Sendable {
    package let sequenceNumber: Int64
    package let duration: TimeInterval
    package let url: URL
    package let byteRange: HLSByteRange?
    package let beginsDiscontinuity: Bool
    package let isGap: Bool
    package let programDateTime: Date?
    package let encryption: HLSLiveAES128EncryptionRecord?
}

package struct HLSLiveInitializationSegmentRecord: Equatable, Sendable {
    package let url: URL
    package let byteRange: HLSByteRange?
    package let encryption: HLSLiveAES128EncryptionRecord?
}

package struct HLSLivePartialSegmentRecord: Equatable, Sendable {
    package let mediaSequenceNumber: Int64
    package let partIndex: Int
    package let duration: TimeInterval
    package let url: URL
    package let byteRange: HLSByteRange?
    package let isIndependent: Bool
    package let isGap: Bool
}

package struct HLSLiveResolvedDocument: Sendable {
    package let playlist: HLSPlaylist
    package let responseFreshness: HLSHTTPResponseFreshness
    package let declaredMediaSequence: Int64
    package let segments: [HLSLiveSegmentRecord]
    package let initializationSegments: [HLSLiveInitializationSegmentRecord]
    package let partialSegments: [HLSLivePartialSegmentRecord]
    package let encryptionMethod: String?
    package let hasEndList: Bool
}

package struct HLSLivePresentationCandidateRecord: Sendable {
    package let variant: HLSVariant
    package let renditions: [HLSRendition]
    package let pathwayID: String?
    package let multivariantVariables: [String: String]
}

package struct HLSLiveResolvedPresentation: Sendable {
    package let document: HLSLiveResolvedDocument
    package let selectedVariant: HLSVariant?
    package let renditions: [HLSRendition]
    package let pathwayID: String?
    package let multivariantVariables: [String: String]
    package let pathwayCandidates: [HLSLivePresentationCandidateRecord]
}

package extension PlaylistResolver {
    func resolveLivePresentation(
        from sourceURL: URL,
        selectionPolicy: HLSVariantSelectionPolicy,
        contentSteering: HLSContentSteeringPack,
        contentSteeringSession: HLSContentSteeringSession,
        requestTimeout: TimeInterval
    ) async throws -> HLSLiveResolvedPresentation {
        let settings = contentSteering.resolvedSettings
        let selection = try await HLSMediaPlaylistResolver(
            client: client,
            selectionPolicy: selectionPolicy,
            contentSteering: settings,
            allowsSeparateAudioRenditions: true
        ).resolve(
            from: sourceURL,
            session: contentSteeringSession,
            requestTimeout: requestTimeout,
            disablesCaching: true
        )
        let pathwayCandidates: [HLSLivePresentationCandidateRecord]
        if settings.allowsTransferFailover,
            let selectedVariant = selection.selectedVariant
        {
            pathwayCandidates = selection.pathwayCandidates.compactMap {
                candidate in
                guard
                    Self.liveVariantsAreCompatible(
                        selectedVariant,
                        candidate.variant
                    )
                else {
                    return nil
                }
                return HLSLivePresentationCandidateRecord(
                    variant: candidate.variant,
                    renditions: candidate.renditions,
                    pathwayID: candidate.pathwayID,
                    multivariantVariables:
                        candidate.multivariantVariables
                )
            }
        } else {
            pathwayCandidates = []
        }
        return HLSLiveResolvedPresentation(
            document: try Self.liveDocument(
                from: selection.playlist,
                responseFreshness: selection.responseFreshness
            ),
            selectedVariant: selection.selectedVariant,
            renditions: selection.renditions,
            pathwayID: selection.pathwayID,
            multivariantVariables: selection.multivariantVariables,
            pathwayCandidates: pathwayCandidates
        )
    }

    func resolveLiveFallback(
        _ candidate: HLSLivePresentationCandidateRecord,
        from requestURL: URL,
        requestTimeout: TimeInterval
    ) async throws -> HLSLiveResolvedDocument {
        let document = try await resolveDocument(
            from: requestURL,
            multivariantVariables:
                candidate.multivariantVariables,
            purpose: .mediaPlaylist,
            requestTimeout: requestTimeout,
            disablesCaching: true
        )
        return try Self.liveDocument(
            from: document.playlist,
            responseFreshness: document.responseFreshness
        )
    }

    func resolveLiveDocument(
        from sourceURL: URL,
        purpose: HLSRequestPurpose,
        requestTimeout: TimeInterval,
        multivariantVariables: [String: String]? = nil
    ) async throws -> HLSLiveResolvedDocument {
        let document = try await resolveDocument(
            from: sourceURL,
            multivariantVariables: multivariantVariables,
            purpose: purpose,
            requestTimeout: requestTimeout,
            disablesCaching: true
        )
        return try Self.liveDocument(
            from: document.playlist,
            responseFreshness: document.responseFreshness
        )
    }

    private static func liveDocument(
        from playlist: HLSPlaylist,
        responseFreshness: HLSHTTPResponseFreshness
    ) throws -> HLSLiveResolvedDocument {
        guard
            playlist.kind == .media,
            let media = playlist.media
        else {
            throw HLSLiveBridgeError.mediaPlaylistRequired
        }

        let skippedCount =
            playlist.lowLatency?.deltaUpdate?
            .skippedSegmentCount ?? 0
        guard let skippedCount64 = Int64(exactly: skippedCount) else {
            throw HLSDownloadError.invalidPlaylist
        }
        let (listedMediaSequence, skippedOverflow) =
            media.mediaSequence.addingReportingOverflow(skippedCount64)
        guard !skippedOverflow else {
            throw HLSDownloadError.invalidPlaylist
        }

        let programDatesBySegmentIndex = Dictionary(
            uniqueKeysWithValues: documentProgramDates(
                in: playlist
            )
        )
        var segmentOffset: Int64 = 0
        var listedSegmentIndex = 0
        var nextProgramDate: Date?
        var segments: [HLSLiveSegmentRecord] = []
        for resource in media.resources where resource.kind == .segment {
            guard let duration = resource.duration else {
                throw HLSDownloadError.invalidPlaylist
            }
            let (sequenceNumber, overflow) =
                listedMediaSequence.addingReportingOverflow(segmentOffset)
            guard !overflow else {
                throw HLSDownloadError.invalidPlaylist
            }
            if let declaredProgramDate =
                programDatesBySegmentIndex[listedSegmentIndex]
            {
                nextProgramDate = declaredProgramDate
            } else if resource.beginsDiscontinuity {
                nextProgramDate = nil
            }
            let programDateTime = nextProgramDate
            segments.append(
                HLSLiveSegmentRecord(
                    sequenceNumber: sequenceNumber,
                    duration: duration,
                    url: resource.url,
                    byteRange: resource.byteRange,
                    beginsDiscontinuity: resource.beginsDiscontinuity,
                    isGap: resource.isGap,
                    programDateTime: programDateTime,
                    encryption: resource.encryption.map {
                        HLSLiveAES128EncryptionRecord(
                            keyURL: $0.keyURL,
                            initializationVector:
                                $0.initializationVector
                        )
                    }
                )
            )
            if let programDateTime {
                nextProgramDate = programDateTime.addingTimeInterval(
                    duration
                )
            }
            let (nextOffset, offsetOverflow) =
                segmentOffset.addingReportingOverflow(1)
            guard !offsetOverflow else {
                throw HLSDownloadError.invalidPlaylist
            }
            segmentOffset = nextOffset
            let (nextIndex, indexOverflow) =
                listedSegmentIndex.addingReportingOverflow(1)
            guard !indexOverflow else {
                throw HLSDownloadError.invalidPlaylist
            }
            listedSegmentIndex = nextIndex
        }

        var nextPartIndexBySegment: [Int: Int] = [:]
        let partialSegments = try (playlist.lowLatency?.partialSegments ?? [])
            .map { partialSegment in
                guard let segmentIndex64 = Int64(exactly: partialSegment.segmentIndex) else {
                    throw HLSDownloadError.invalidPlaylist
                }
                let (mediaSequenceNumber, overflow) =
                    listedMediaSequence.addingReportingOverflow(segmentIndex64)
                guard !overflow else {
                    throw HLSDownloadError.invalidPlaylist
                }
                let partIndex =
                    nextPartIndexBySegment[partialSegment.segmentIndex, default: 0]
                let (nextPartIndex, indexOverflow) =
                    partIndex.addingReportingOverflow(1)
                guard !indexOverflow else {
                    throw HLSDownloadError.invalidPlaylist
                }
                nextPartIndexBySegment[partialSegment.segmentIndex] =
                    nextPartIndex
                return HLSLivePartialSegmentRecord(
                    mediaSequenceNumber: mediaSequenceNumber,
                    partIndex: partIndex,
                    duration: partialSegment.duration,
                    url: partialSegment.url,
                    byteRange: partialSegment.byteRange,
                    isIndependent: partialSegment.isIndependent,
                    isGap: partialSegment.isGap
                )
            }

        return HLSLiveResolvedDocument(
            playlist: playlist,
            responseFreshness: responseFreshness,
            declaredMediaSequence: media.mediaSequence,
            segments: segments,
            initializationSegments: media.resources.compactMap {
                resource in
                guard resource.kind == .initialization else {
                    return nil
                }
                return HLSLiveInitializationSegmentRecord(
                    url: resource.url,
                    byteRange: resource.byteRange,
                    encryption: resource.encryption.map {
                        HLSLiveAES128EncryptionRecord(
                            keyURL: $0.keyURL,
                            initializationVector:
                                $0.initializationVector
                        )
                    }
                )
            },
            partialSegments: partialSegments,
            encryptionMethod: media.encryptionMethod,
            hasEndList: media.hasEndList
        )
    }

    private static func documentProgramDates(
        in playlist: HLSPlaylist
    ) -> [(Int, Date)] {
        playlist.programDateTimes.map {
            ($0.segmentIndex, $0.date)
        }
    }

    private static func liveVariantsAreCompatible(
        _ primary: HLSVariant,
        _ candidate: HLSVariant
    ) -> Bool {
        guard
            let stableID = primary.stableID,
            stableID == candidate.stableID
        else {
            return false
        }
        return primary.codecs == candidate.codecs
            && primary.supplementalCodecs
                == candidate.supplementalCodecs
            && primary.width == candidate.width
            && primary.height == candidate.height
            && primary.videoRange == candidate.videoRange
    }
}
