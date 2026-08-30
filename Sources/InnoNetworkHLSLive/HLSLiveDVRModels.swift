import Foundation

/// A live feature that the bounded DVR writer cannot preserve safely.
public enum HLSLiveDVRUnsupportedFeature: Equatable, Sendable {
    /// One or more complete segments are intentionally absent.
    case gap

    /// Media uses DRM or sample encryption that cannot become plaintext.
    case encryptedMedia

    /// The stream has no container supported by the local playlist writer.
    case unknownMediaContainer

    /// A fragmented MP4 presentation omitted its initialization map.
    case missingInitializationSegment

    /// The initialization map changed while recording was in progress.
    case changingInitializationSegment

    /// The selected variant requires a separately stored rendition playlist.
    case externalRendition

    /// A Date Range references media or metadata outside the primary stream.
    case externalTimelineResource
}

/// A bounded live DVR recording failure.
public enum HLSLiveDVRError: Error, Equatable, Sendable {
    /// The destination is not a local file URL.
    case invalidDestination

    /// An item already exists at the destination.
    case destinationAlreadyExists

    /// Another task or process owns the destination lease.
    case destinationInUse

    /// No complete segment fit within the configured limits.
    case noSegmentsRecorded

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
        case .noSegmentsRecorded:
            return "No complete live segment fit within the recording limits."
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
        case .noSegmentsRecorded:
            return "Increase the duration or byte limits and record again."
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
            return "timeline gap"
        case .encryptedMedia:
            return "DRM or sample-encrypted media"
        case .unknownMediaContainer:
            return "unknown media container"
        case .missingInitializationSegment:
            return "missing initialization segment"
        case .changingInitializationSegment:
            return "changing initialization segment"
        case .externalRendition:
            return "external rendition"
        case .externalTimelineResource:
            return "external timeline resource"
        }
    }
}

/// A bounded live DVR progress snapshot.
public struct HLSLiveDVRProgress: Equatable, Sendable {
    /// The number of retained complete segments.
    public let segmentCount: Int

    /// The retained playback duration in seconds.
    public let recordedDuration: TimeInterval

    /// Initialization and complete-segment bytes retained so far.
    public let mediaByteCount: Int64

    init(
        segmentCount: Int,
        recordedDuration: TimeInterval,
        mediaByteCount: Int64
    ) {
        self.segmentCount = segmentCount
        self.recordedDuration = recordedDuration
        self.mediaByteCount = mediaByteCount
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

    /// The number of retained complete segments.
    public let segmentCount: Int

    /// The retained playback duration in seconds.
    public let recordedDuration: TimeInterval

    /// Initialization and complete-segment bytes retained in the package.
    public let mediaByteCount: Int64

    /// The first retained media-sequence number.
    public let firstMediaSequence: Int64

    /// The last retained media-sequence number.
    public let lastMediaSequence: Int64

    init(
        directoryURL: URL,
        playlistURL: URL,
        segmentCount: Int,
        recordedDuration: TimeInterval,
        mediaByteCount: Int64,
        firstMediaSequence: Int64,
        lastMediaSequence: Int64
    ) {
        self.directoryURL = directoryURL
        self.playlistURL = playlistURL
        self.segmentCount = segmentCount
        self.recordedDuration = recordedDuration
        self.mediaByteCount = mediaByteCount
        self.firstMediaSequence = firstMediaSequence
        self.lastMediaSequence = lastMediaSequence
    }
}
