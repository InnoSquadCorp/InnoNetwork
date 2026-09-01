import Foundation
import InnoNetworkHLS

/// A live feature that the bounded DVR writer cannot preserve safely.
public enum HLSLiveDVRUnsupportedFeature: Equatable, Sendable {
    /// A retained segment's declared availability changed retroactively.
    case gap

    /// Media uses DRM or sample encryption that cannot become plaintext.
    case encryptedMedia

    /// The stream has no container supported by the local playlist writer.
    case unknownMediaContainer

    /// A fragmented MP4 presentation omitted its initialization map.
    case missingInitializationSegment

    /// A retained segment's map changed, or a transport-stream segment
    /// unexpectedly declared an initialization map.
    case changingInitializationSegment

    /// The selected variant requires a separately stored rendition playlist.
    case externalRendition

    /// A Date Range references media or metadata outside the primary stream.
    case externalTimelineResource

    /// A Date Range contains extension values unavailable after redaction.
    case unrepresentableTimelineMetadata

    /// A selected rendition could not remain complete with the primary track.
    case incompleteExternalRendition
}

/// A bounded live DVR recording failure.
public enum HLSLiveDVRError: Error, Equatable, Sendable {
    /// The destination is not a local file URL.
    case invalidDestination

    /// An item already exists at the destination.
    case destinationAlreadyExists

    /// Another task or process owns the destination lease.
    case destinationInUse

    /// A recoverable checkpoint already owns this destination.
    case recoveryAlreadyExists

    /// Resumable recording is disabled by configuration.
    case recoveryDisabled

    /// No valid checkpoint exists for the requested destination.
    case recoveryUnavailable

    /// The checkpoint belongs to another source or selection contract.
    case recoveryMismatch

    /// Checkpoint metadata or retained media failed integrity validation.
    case recoveryCorrupted

    /// No complete segment fit within the configured limits.
    case noSegmentsRecorded

    /// Rendition selection exceeded the configured per-kind limit.
    case renditionLimitExceeded(limit: Int)

    /// The live window advanced past an unrecorded complete segment.
    case liveWindowAdvanced

    /// The source uses a feature the local package cannot preserve safely.
    case unsupportedFeature(HLSLiveDVRUnsupportedFeature)

    /// One media resource exceeded the configured per-resource byte limit.
    case mediaResourceTooLarge

    /// A ranged response did not match the requested byte interval.
    case invalidByteRangeResponse

    /// A media request returned a non-success HTTP status.
    case invalidMediaResponseStatus(Int)

    /// An AES-128 key response was not exactly 16 bytes.
    case invalidEncryptionKey

    /// An AES-128 key request returned a non-success HTTP status.
    case invalidEncryptionKeyResponseStatus(Int)

    /// AES-128 media could not be decrypted or had invalid padding.
    case decryptionFailed

    /// Available capacity could not be read under a required disk policy.
    case diskCapacityUnavailable

    /// The destination volume cannot satisfy the configured disk policy.
    case insufficientDiskCapacity(required: Int64, available: Int64)

    /// A media transfer failed without exposing transport details.
    case transferFailed

    /// Local staging or atomic commit failed.
    case storageFailed
}

extension HLSLiveDVRError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidDestination:
            return "The live DVR destination is not a local file URL."
        case .destinationAlreadyExists:
            return "An item already exists at the live DVR destination."
        case .destinationInUse:
            return "Another task or process is writing to the live DVR destination."
        case .recoveryAlreadyExists:
            return "A recoverable live DVR checkpoint already owns this destination."
        case .recoveryDisabled:
            return "Live DVR recovery is disabled by the current configuration."
        case .recoveryUnavailable:
            return "No recoverable live DVR checkpoint exists for this destination."
        case .recoveryMismatch:
            return "The live DVR checkpoint does not match the requested source or rendition selection."
        case .recoveryCorrupted:
            return "The live DVR checkpoint or retained media failed integrity validation."
        case .noSegmentsRecorded:
            return "No complete live segment fit within the recording limits."
        case .renditionLimitExceeded(let limit):
            return "Live DVR rendition selection exceeded the per-kind limit of \(limit)."
        case .liveWindowAdvanced:
            return "The live window advanced before every complete segment could be recorded."
        case .unsupportedFeature(let feature):
            return
                "The live DVR source uses an unsupported feature: "
                + feature.description + "."
        case .mediaResourceTooLarge:
            return "A live DVR media resource exceeded its byte limit."
        case .invalidByteRangeResponse:
            return "A live DVR byte-range response did not match the requested interval."
        case .invalidMediaResponseStatus(let statusCode):
            return "A live DVR media request returned HTTP \(statusCode)."
        case .invalidEncryptionKey:
            return "A live DVR AES-128 key response was not exactly 16 bytes."
        case .invalidEncryptionKeyResponseStatus(let statusCode):
            return "A live DVR AES-128 key request returned HTTP \(statusCode)."
        case .decryptionFailed:
            return "A live DVR AES-128 resource could not be decrypted."
        case .diskCapacityUnavailable:
            return "Available capacity could not be read for the live DVR destination."
        case .insufficientDiskCapacity(let required, let available):
            return "The live DVR destination requires \(required) available bytes but reports \(available)."
        case .transferFailed:
            return "A live DVR media transfer failed."
        case .storageFailed:
            return "The live DVR package could not be written atomically."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .invalidDestination:
            return "Choose a new local directory URL."
        case .destinationAlreadyExists:
            return "Choose a destination that does not already exist."
        case .destinationInUse:
            return "Wait for the other writer to finish or choose another destination."
        case .recoveryAlreadyExists:
            return "Resume or explicitly discard the existing recording before starting again."
        case .recoveryDisabled:
            return "Enable the resumable recovery policy before requesting resume."
        case .recoveryUnavailable:
            return "Start a new resumable recording for this destination."
        case .recoveryMismatch:
            return "Resume with the original source and rendition configuration, or discard the checkpoint."
        case .recoveryCorrupted:
            return "Discard the checkpoint and start a new recording."
        case .noSegmentsRecorded:
            return "Increase the duration or byte limits and record again."
        case .renditionLimitExceeded:
            return "Select fewer rendition languages or raise the bounded rendition limit."
        case .liveWindowAdvanced:
            return "Use a faster connection or lower-bitrate variant and start a new recording."
        case .unsupportedFeature:
            return "Use AVFoundation playback or a persistence path that supports the source feature."
        case .mediaResourceTooLarge:
            return "Increase the per-resource limit only for a trusted source."
        case .invalidByteRangeResponse:
            return "Verify that the origin honors exact HLS byte-range requests."
        case .invalidMediaResponseStatus, .invalidEncryptionKeyResponseStatus,
            .transferFailed:
            return "Check connectivity and source availability, then start a new recording."
        case .invalidEncryptionKey, .decryptionFailed:
            return "Verify the AES-128 key and media authoring, then start a new recording."
        case .diskCapacityUnavailable:
            return "Allow capacity inspection or choose a best-effort disk policy."
        case .insufficientDiskCapacity:
            return "Free destination storage or lower the recording limits, then retry."
        case .storageFailed:
            return "Check destination permissions and available storage, then retry."
        }
    }
}

private extension HLSLiveDVRUnsupportedFeature {
    var description: String {
        switch self {
        case .gap:
            return "incompatible gap history"
        case .encryptedMedia:
            return "DRM or sample-encrypted media"
        case .unknownMediaContainer:
            return "unknown media container"
        case .missingInitializationSegment:
            return "missing initialization segment"
        case .changingInitializationSegment:
            return "incompatible initialization-map history"
        case .externalRendition:
            return "external rendition"
        case .externalTimelineResource:
            return "external timeline resource"
        case .unrepresentableTimelineMetadata:
            return "unrepresentable timeline metadata"
        case .incompleteExternalRendition:
            return "incomplete external rendition"
        }
    }
}

/// The role of one local playlist in a live DVR package.
public enum HLSLiveDVRTrackKind: Equatable, Hashable, Sendable {
    /// The selected primary variant or direct media playlist.
    case primary

    /// One external audio rendition.
    case audio

    /// One external subtitle rendition.
    case subtitles

    /// One external alternate-video rendition.
    case video
}

/// Non-sensitive metadata for one local live DVR playlist.
public struct HLSLiveDVRTrack: Equatable, Sendable {
    /// The local track role.
    public let kind: HLSLiveDVRTrackKind

    /// The source rendition name, or `nil` for the primary track.
    public let name: String?

    /// The source BCP 47 language tag.
    public let language: String?

    /// The source's stable rendition identifier.
    public let stableID: String?

    /// Media characteristic tags retained in playlist order.
    public let characteristics: [String]

    /// Typed media characteristics retained from the source rendition.
    public var mediaCharacteristics: [HLSMediaCharacteristic] {
        characteristics.map(HLSMediaCharacteristic.init(rawValue:))
    }

    /// Returns whether this track retains the exact characteristic.
    public func hasCharacteristic(
        _ characteristic: HLSMediaCharacteristic
    ) -> Bool {
        characteristics.contains(characteristic.rawValue)
    }

    /// Whether this track was authored or translated programmatically.
    public var isMachineGenerated: Bool {
        hasCharacteristic(.machineGenerated)
    }

    /// Whether this track is marked as a translation.
    public var isTranslated: Bool {
        hasCharacteristic(.translation)
    }

    /// The playlist path relative to the package directory.
    public let relativePlaylistPath: String

    init(
        kind: HLSLiveDVRTrackKind,
        name: String?,
        language: String?,
        stableID: String?,
        characteristics: [String] = [],
        relativePlaylistPath: String
    ) {
        self.kind = kind
        self.name = name
        self.language = language
        self.stableID = stableID
        self.characteristics = characteristics
        self.relativePlaylistPath = relativePlaylistPath
    }
}

/// Cumulative media removed by rolling live DVR retention.
public struct HLSLiveDVRRetentionStatistics: Equatable, Sendable {
    /// The number of evicted primary-track segments, including gaps.
    public let evictedPrimarySegmentCount: Int

    /// The evicted primary-track playback duration in seconds.
    public let evictedPrimaryDuration: TimeInterval

    /// Bytes removed across primary, rendition, and initialization media.
    public let evictedMediaByteCount: Int64

    init(
        evictedPrimarySegmentCount: Int = 0,
        evictedPrimaryDuration: TimeInterval = 0,
        evictedMediaByteCount: Int64 = 0
    ) {
        self.evictedPrimarySegmentCount = evictedPrimarySegmentCount
        self.evictedPrimaryDuration = evictedPrimaryDuration
        self.evictedMediaByteCount = evictedMediaByteCount
    }

    func adding(
        primarySegmentCount: Int = 0,
        primaryDuration: TimeInterval = 0,
        mediaByteCount: Int64 = 0
    ) throws -> HLSLiveDVRRetentionStatistics {
        let (segmentCount, segmentOverflow) =
            evictedPrimarySegmentCount.addingReportingOverflow(
                primarySegmentCount
            )
        let duration = evictedPrimaryDuration + primaryDuration
        let (byteCount, byteOverflow) =
            evictedMediaByteCount.addingReportingOverflow(
                mediaByteCount
            )
        guard !segmentOverflow,
            duration.isFinite,
            !byteOverflow
        else {
            throw HLSLiveDVRError.storageFailed
        }
        return HLSLiveDVRRetentionStatistics(
            evictedPrimarySegmentCount: segmentCount,
            evictedPrimaryDuration: duration,
            evictedMediaByteCount: byteCount
        )
    }
}

/// A bounded live DVR progress snapshot.
public struct HLSLiveDVRProgress: Equatable, Sendable {
    /// The number of retained complete segments, including declared gaps.
    public let segmentCount: Int

    /// The number of retained primary-track `EXT-X-GAP` segments.
    public let gapCount: Int

    /// The retained playback duration in seconds.
    public let recordedDuration: TimeInterval

    /// Initialization and complete-segment bytes retained so far.
    public let mediaByteCount: Int64

    /// Partial segments currently staged for one incomplete parent segment.
    public let stagedPartCount: Int

    /// Playback duration represented by the currently staged parts.
    public let stagedPartDuration: TimeInterval

    /// Temporary bytes currently retained for staged parts.
    public let stagedPartByteCount: Int64

    /// Parts promoted into complete retained segments so far.
    public let promotedPartCount: Int

    /// Value-redacted LL-HLS preload counters for this recording session.
    public let preloadStatistics: HLSLiveDVRPreloadStatistics

    /// Cumulative media removed by rolling retention.
    public let retentionStatistics: HLSLiveDVRRetentionStatistics

    init(
        segmentCount: Int,
        gapCount: Int = 0,
        recordedDuration: TimeInterval,
        mediaByteCount: Int64,
        stagedPartCount: Int = 0,
        stagedPartDuration: TimeInterval = 0,
        stagedPartByteCount: Int64 = 0,
        promotedPartCount: Int = 0,
        preloadStatistics: HLSLiveDVRPreloadStatistics =
            HLSLiveDVRPreloadStatistics(),
        retentionStatistics: HLSLiveDVRRetentionStatistics =
            HLSLiveDVRRetentionStatistics()
    ) {
        self.segmentCount = segmentCount
        self.gapCount = gapCount
        self.recordedDuration = recordedDuration
        self.mediaByteCount = mediaByteCount
        self.stagedPartCount = stagedPartCount
        self.stagedPartDuration = stagedPartDuration
        self.stagedPartByteCount = stagedPartByteCount
        self.promotedPartCount = promotedPartCount
        self.preloadStatistics = preloadStatistics
        self.retentionStatistics = retentionStatistics
    }
}

/// A non-sensitive live DVR recording update.
public enum HLSLiveDVREvent: Equatable, Sendable {
    /// A complete segment was retained.
    case progress(HLSLiveDVRProgress)

    /// The package was atomically committed.
    case completed(HLSLiveDVRReceipt)
}

/// The atomically committed result of a bounded live DVR recording.
public struct HLSLiveDVRReceipt: Equatable, Sendable {
    /// The committed package directory.
    public let directoryURL: URL

    /// The local VOD media playlist.
    public let playlistURL: URL

    /// The local package entry point.
    ///
    /// This is `master.m3u8` when external renditions or in-band caption
    /// declarations were retained, and the primary media playlist otherwise.
    public let entryPlaylistURL: URL

    /// A structurally validated source for application-owned local playback.
    public var playbackSource: HLSLocalPlaybackSource {
        HLSLocalPlaybackSource(
            validatedPackageDirectoryURL: directoryURL,
            entryPlaylistURL: entryPlaylistURL
        )
    }

    /// The local playlists retained in the package.
    public let tracks: [HLSLiveDVRTrack]

    /// The number of retained complete segments, including declared gaps.
    public let segmentCount: Int

    /// The number of retained primary-track `EXT-X-GAP` segments.
    public let gapCount: Int

    /// The retained playback duration in seconds.
    public let recordedDuration: TimeInterval

    /// Initialization and complete-segment bytes retained in the package.
    public let mediaByteCount: Int64

    /// Partial segments promoted without refetching their complete parent.
    public let promotedPartCount: Int

    /// Value-redacted LL-HLS preload counters for this recording session.
    public let preloadStatistics: HLSLiveDVRPreloadStatistics

    /// Cumulative media removed by rolling retention.
    public let retentionStatistics: HLSLiveDVRRetentionStatistics

    /// The first retained media-sequence number.
    public let firstMediaSequence: Int64

    /// The last retained media-sequence number.
    public let lastMediaSequence: Int64

    init(
        directoryURL: URL,
        playlistURL: URL,
        entryPlaylistURL: URL,
        tracks: [HLSLiveDVRTrack],
        segmentCount: Int,
        gapCount: Int = 0,
        recordedDuration: TimeInterval,
        mediaByteCount: Int64,
        promotedPartCount: Int = 0,
        preloadStatistics: HLSLiveDVRPreloadStatistics =
            HLSLiveDVRPreloadStatistics(),
        retentionStatistics: HLSLiveDVRRetentionStatistics =
            HLSLiveDVRRetentionStatistics(),
        firstMediaSequence: Int64,
        lastMediaSequence: Int64
    ) {
        self.directoryURL = directoryURL
        self.playlistURL = playlistURL
        self.entryPlaylistURL = entryPlaylistURL
        self.tracks = tracks
        self.segmentCount = segmentCount
        self.gapCount = gapCount
        self.recordedDuration = recordedDuration
        self.mediaByteCount = mediaByteCount
        self.promotedPartCount = promotedPartCount
        self.preloadStatistics = preloadStatistics
        self.retentionStatistics = retentionStatistics
        self.firstMediaSequence = firstMediaSequence
        self.lastMediaSequence = lastMediaSequence
    }
}
