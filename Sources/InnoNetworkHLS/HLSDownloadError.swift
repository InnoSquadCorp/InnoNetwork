import Foundation
import InnoNetwork

/// Stable integer codes surfaced by ``HLSDownloadError`` through its
/// `CustomNSError` bridge. Raw values are part of the public contract and must
/// not be renumbered.
public enum HLSDownloadErrorCode: Int, Hashable, Sendable {
    case invalidPlaylist = 7_001
    case invalidResponseStatus = 7_002
    case playlistTooLarge = 7_003
    case emptyMediaPlaylist = 7_004
    case livePlaylistUnsupported = 7_005
    case encryptedPlaylistUnsupported = 7_006
    case byteRangePlaylistUnsupported = 7_007
    case separateAudioRenditionUnsupported = 7_008
    case invalidMediaResponseStatus = 7_009
    case mediaResourceTooLarge = 7_010
    case totalDownloadTooLarge = 7_011
    case diskCapacityUnavailable = 7_012
    case insufficientDiskCapacity = 7_013
    case transferFailed = 7_014
    case emptyOutput = 7_015
    case destinationAlreadyExists = 7_016
    case invalidDestination = 7_017
    case destinationInUse = 7_018
    case noVariantMatchesSelectionPolicy = 7_019
    case incompleteDownload = 7_020
    case unsupportedMediaFeature = 7_021
    case invalidByteRangeResponse = 7_022
    case offlineRenditionLimitExceeded = 7_023
    case invalidAES128Key = 7_024
    case aes128DecryptionFailed = 7_025
    case invalidAES128KeyResponseStatus = 7_026
    case invalidOfflinePackage = 7_027
    case unsupportedOfflinePackageSchema = 7_028
}

/// Failures produced by playlist resolution and HLS media download.
public enum HLSDownloadError: Error, Equatable, Sendable {
    /// The response was not a syntactically recognizable HLS playlist.
    case invalidPlaylist

    /// A playlist request returned a non-success HTTP status.
    case invalidResponseStatus(Int)

    /// The playlist response exceeded the resolver's bounded byte limit.
    case playlistTooLarge(limit: Int)

    /// A media playlist contained no downloadable segments.
    case emptyMediaPlaylist

    /// Live playlists are unbounded and cannot be committed as one file.
    case livePlaylistUnsupported

    /// An encryption method other than identity-format AES-128 requires a
    /// specialized content-key integration.
    case encryptedPlaylistUnsupported(method: String)

    /// A legacy classification retained for source compatibility.
    ///
    /// Valid byte-range playlists are supported and the downloader no longer
    /// emits this case.
    case byteRangePlaylistUnsupported

    /// Separate audio renditions require multi-playlist media assembly.
    case separateAudioRenditionUnsupported(groupID: String)

    /// The playlist uses a feature that raw single-file assembly cannot
    /// preserve safely.
    case unsupportedMediaFeature(HLSUnsupportedMediaFeature)

    /// A ranged media response did not match the requested byte interval.
    case invalidByteRangeResponse

    /// No supported variant satisfied the configured quality constraint.
    case noVariantMatchesSelectionPolicy(HLSVariantSelectionPolicy)

    /// A media segment request returned a non-success HTTP status.
    case invalidMediaResponseStatus(Int)

    /// A media response exceeded the per-resource byte limit.
    case mediaResourceTooLarge(limit: Int)

    /// The assembled media exceeded the total download byte limit.
    case totalDownloadTooLarge(limit: Int64)

    /// Available disk capacity could not be determined for the destination.
    case diskCapacityUnavailable

    /// The destination volume doesn't have the configured free capacity.
    case insufficientDiskCapacity(required: Int64, available: Int64)

    /// A media resource transfer failed. The value preserves a stable
    /// `NSError` domain/code projection and bounded underlying-error chain.
    case transferFailed(SendableUnderlyingError)

    /// The download reported success but produced no media bytes.
    case emptyOutput

    /// A file already exists at the requested destination.
    case destinationAlreadyExists

    /// The requested destination is not a local file URL.
    case invalidDestination

    /// Another process or task is writing to the requested destination.
    case destinationInUse

    /// The event stream ended without a terminal result.
    case incompleteDownload

    /// Offline package selection exceeded its bounded rendition count.
    case offlineRenditionLimitExceeded(limit: Int)

    /// An AES-128 key response was not exactly 16 bytes.
    case invalidAES128Key

    /// AES-128-CBC decryption failed validation.
    case aes128DecryptionFailed

    /// An AES-128 key request returned a non-success HTTP status.
    case invalidAES128KeyResponseStatus(Int)

    /// A local offline package failed structural or integrity validation.
    case invalidOfflinePackage

    /// A local offline package uses a newer or unknown manifest schema.
    case unsupportedOfflinePackageSchema(version: Int)
}

extension HLSDownloadError: LocalizedError {
    /// Localized human-readable summary of the failure.
    public var errorDescription: String? {
        switch self {
        case .invalidPlaylist:
            return hlsLocalized("HLSDownloadError.invalidPlaylist")
        case .invalidResponseStatus(let statusCode):
            return hlsLocalizedFormat(
                "HLSDownloadError.invalidResponseStatus",
                String(statusCode)
            )
        case .playlistTooLarge(let limit):
            return hlsLocalizedFormat(
                "HLSDownloadError.playlistTooLarge",
                String(limit)
            )
        case .emptyMediaPlaylist:
            return hlsLocalized("HLSDownloadError.emptyMediaPlaylist")
        case .livePlaylistUnsupported:
            return hlsLocalized("HLSDownloadError.livePlaylistUnsupported")
        case .encryptedPlaylistUnsupported(let method):
            return hlsLocalizedFormat(
                "HLSDownloadError.encryptedPlaylistUnsupported",
                method
            )
        case .byteRangePlaylistUnsupported:
            return hlsLocalized(
                "HLSDownloadError.byteRangePlaylistUnsupported"
            )
        case .separateAudioRenditionUnsupported(let groupID):
            return hlsLocalizedFormat(
                "HLSDownloadError.separateAudioRenditionUnsupported",
                groupID
            )
        case .unsupportedMediaFeature(let feature):
            return hlsLocalizedFormat(
                "HLSDownloadError.unsupportedMediaFeature",
                feature.diagnosticDescription
            )
        case .invalidByteRangeResponse:
            return hlsLocalized("HLSDownloadError.invalidByteRangeResponse")
        case .noVariantMatchesSelectionPolicy(let policy):
            return hlsLocalizedFormat(
                "HLSDownloadError.noVariantMatchesSelectionPolicy",
                policy.diagnosticDescription
            )
        case .invalidMediaResponseStatus(let statusCode):
            return hlsLocalizedFormat(
                "HLSDownloadError.invalidMediaResponseStatus",
                String(statusCode)
            )
        case .mediaResourceTooLarge(let limit):
            return hlsLocalizedFormat(
                "HLSDownloadError.mediaResourceTooLarge",
                String(limit)
            )
        case .totalDownloadTooLarge(let limit):
            return hlsLocalizedFormat(
                "HLSDownloadError.totalDownloadTooLarge",
                String(limit)
            )
        case .diskCapacityUnavailable:
            return hlsLocalized("HLSDownloadError.diskCapacityUnavailable")
        case .insufficientDiskCapacity(let required, let available):
            return hlsLocalizedFormat(
                "HLSDownloadError.insufficientDiskCapacity",
                String(required),
                String(available)
            )
        case .transferFailed(let underlying):
            return hlsLocalizedFormat(
                "HLSDownloadError.transferFailed",
                underlying.message
            )
        case .emptyOutput:
            return hlsLocalized("HLSDownloadError.emptyOutput")
        case .destinationAlreadyExists:
            return hlsLocalized("HLSDownloadError.destinationAlreadyExists")
        case .invalidDestination:
            return hlsLocalized("HLSDownloadError.invalidDestination")
        case .destinationInUse:
            return hlsLocalized("HLSDownloadError.destinationInUse")
        case .incompleteDownload:
            return hlsLocalized("HLSDownloadError.incompleteDownload")
        case .offlineRenditionLimitExceeded(let limit):
            return hlsLocalizedFormat(
                "HLSDownloadError.offlineRenditionLimitExceeded",
                String(limit)
            )
        case .invalidAES128Key:
            return hlsLocalized("HLSDownloadError.invalidAES128Key")
        case .aes128DecryptionFailed:
            return hlsLocalized("HLSDownloadError.aes128DecryptionFailed")
        case .invalidAES128KeyResponseStatus(let statusCode):
            return hlsLocalizedFormat(
                "HLSDownloadError.invalidAES128KeyResponseStatus",
                String(statusCode)
            )
        case .invalidOfflinePackage:
            return hlsLocalized("HLSDownloadError.invalidOfflinePackage")
        case .unsupportedOfflinePackageSchema(let version):
            return hlsLocalizedFormat(
                "HLSDownloadError.unsupportedOfflinePackageSchema",
                String(version)
            )
        }
    }

    /// Localized, actionable next step for this failure.
    public var recoverySuggestion: String? {
        switch self {
        case .invalidPlaylist, .emptyMediaPlaylist:
            return hlsLocalized("HLSDownloadError.recovery.validatePlaylist")
        case .invalidResponseStatus(let statusCode),
            .invalidMediaResponseStatus(let statusCode),
            .invalidAES128KeyResponseStatus(let statusCode):
            if Self.isRetriableStatus(statusCode) {
                return hlsLocalized(
                    "HLSDownloadError.recovery.retryTransientHTTP"
                )
            }
            if statusCode == 401 || statusCode == 403 {
                return hlsLocalized(
                    "HLSDownloadError.recovery.verifyCredentials"
                )
            }
            return hlsLocalized("HLSDownloadError.recovery.verifyHTTPSource")
        case .playlistTooLarge, .mediaResourceTooLarge, .totalDownloadTooLarge:
            return hlsLocalized("HLSDownloadError.recovery.adjustSafetyLimit")
        case .livePlaylistUnsupported:
            return hlsLocalized("HLSDownloadError.recovery.useSystemPlayback")
        case .encryptedPlaylistUnsupported:
            return hlsLocalized(
                "HLSDownloadError.recovery.useContentKeyIntegration"
            )
        case .byteRangePlaylistUnsupported:
            return hlsLocalized("HLSDownloadError.recovery.removeLegacyCase")
        case .separateAudioRenditionUnsupported:
            return hlsLocalized("HLSDownloadError.recovery.useOfflinePackage")
        case .unsupportedMediaFeature:
            return hlsLocalized(
                "HLSDownloadError.recovery.useSystemAssetDownload"
            )
        case .invalidByteRangeResponse:
            return hlsLocalized("HLSDownloadError.recovery.fixRangeResponse")
        case .noVariantMatchesSelectionPolicy:
            return hlsLocalized("HLSDownloadError.recovery.adjustSelection")
        case .diskCapacityUnavailable:
            return hlsLocalized("HLSDownloadError.recovery.adjustDiskPolicy")
        case .insufficientDiskCapacity:
            return hlsLocalized("HLSDownloadError.recovery.freeDiskCapacity")
        case .transferFailed(let underlying):
            return underlying.recoverySuggestion
                ?? hlsLocalized("HLSDownloadError.recovery.retryTransfer")
        case .emptyOutput:
            return hlsLocalized("HLSDownloadError.recovery.inspectMediaSource")
        case .destinationAlreadyExists:
            return hlsLocalized(
                "HLSDownloadError.recovery.chooseEmptyDestination"
            )
        case .invalidDestination:
            return hlsLocalized("HLSDownloadError.recovery.useFileURL")
        case .destinationInUse:
            return hlsLocalized("HLSDownloadError.recovery.waitForDestination")
        case .incompleteDownload:
            return hlsLocalized("HLSDownloadError.recovery.restartDownload")
        case .offlineRenditionLimitExceeded:
            return hlsLocalized("HLSDownloadError.recovery.limitRenditions")
        case .invalidAES128Key:
            return hlsLocalized("HLSDownloadError.recovery.fixAES128Key")
        case .aes128DecryptionFailed:
            return hlsLocalized(
                "HLSDownloadError.recovery.verifyAES128Metadata"
            )
        case .invalidOfflinePackage,
            .unsupportedOfflinePackageSchema:
            return hlsLocalized(
                "HLSDownloadError.recovery.redownloadOfflinePackage"
            )
        }
    }
}

extension HLSDownloadError: CustomNSError {
    public static let errorDomain = "com.innosquad.innonetwork.hls"
    public static let errorCodeUserInfoKey = "InnoNetworkHLSErrorCode"
    public static let statusCodeUserInfoKey = "InnoNetworkHLSStatusCode"

    public var errorCode: Int {
        code.rawValue
    }

    public var errorUserInfo: [String: Any] {
        var userInfo: [String: Any] = [
            NSLocalizedDescriptionKey:
                errorDescription ?? hlsLocalized("HLSDownloadError.fallback"),
            Self.errorCodeUserInfoKey: errorCode,
        ]
        if let recoverySuggestion {
            userInfo[NSLocalizedRecoverySuggestionErrorKey] =
                recoverySuggestion
        }
        if case .transferFailed(let underlying) = self {
            userInfo[NSUnderlyingErrorKey] = underlying
        }
        switch self {
        case .invalidResponseStatus(let statusCode),
            .invalidMediaResponseStatus(let statusCode),
            .invalidAES128KeyResponseStatus(let statusCode):
            userInfo[Self.statusCodeUserInfoKey] = statusCode
        default:
            break
        }
        return userInfo
    }

    /// Stable machine-readable classification for logging and recovery paths.
    public var code: HLSDownloadErrorCode {
        switch self {
        case .invalidPlaylist: return .invalidPlaylist
        case .invalidResponseStatus: return .invalidResponseStatus
        case .playlistTooLarge: return .playlistTooLarge
        case .emptyMediaPlaylist: return .emptyMediaPlaylist
        case .livePlaylistUnsupported: return .livePlaylistUnsupported
        case .encryptedPlaylistUnsupported:
            return .encryptedPlaylistUnsupported
        case .byteRangePlaylistUnsupported:
            return .byteRangePlaylistUnsupported
        case .separateAudioRenditionUnsupported:
            return .separateAudioRenditionUnsupported
        case .unsupportedMediaFeature:
            return .unsupportedMediaFeature
        case .invalidByteRangeResponse:
            return .invalidByteRangeResponse
        case .noVariantMatchesSelectionPolicy:
            return .noVariantMatchesSelectionPolicy
        case .invalidMediaResponseStatus:
            return .invalidMediaResponseStatus
        case .mediaResourceTooLarge: return .mediaResourceTooLarge
        case .totalDownloadTooLarge: return .totalDownloadTooLarge
        case .diskCapacityUnavailable: return .diskCapacityUnavailable
        case .insufficientDiskCapacity: return .insufficientDiskCapacity
        case .transferFailed: return .transferFailed
        case .emptyOutput: return .emptyOutput
        case .destinationAlreadyExists: return .destinationAlreadyExists
        case .invalidDestination: return .invalidDestination
        case .destinationInUse: return .destinationInUse
        case .incompleteDownload: return .incompleteDownload
        case .offlineRenditionLimitExceeded:
            return .offlineRenditionLimitExceeded
        case .invalidAES128Key:
            return .invalidAES128Key
        case .aes128DecryptionFailed:
            return .aes128DecryptionFailed
        case .invalidAES128KeyResponseStatus:
            return .invalidAES128KeyResponseStatus
        case .invalidOfflinePackage:
            return .invalidOfflinePackage
        case .unsupportedOfflinePackageSchema:
            return .unsupportedOfflinePackageSchema
        }
    }
}

extension HLSDownloadError {
    /// Conservative hint for UI and policy code that needs a retry affordance.
    ///
    /// This does not override the configured core retry policy. It only
    /// answers whether this terminal error is usually transient.
    public var isRetriableHint: Bool {
        switch self {
        case .invalidResponseStatus(let statusCode),
            .invalidMediaResponseStatus(let statusCode),
            .invalidAES128KeyResponseStatus(let statusCode):
            return Self.isRetriableStatus(statusCode)
        case .transferFailed(let underlying):
            return !Self.isCancellation(underlying)
        case .destinationInUse:
            return true
        case .invalidPlaylist,
            .playlistTooLarge,
            .emptyMediaPlaylist,
            .livePlaylistUnsupported,
            .encryptedPlaylistUnsupported,
            .byteRangePlaylistUnsupported,
            .separateAudioRenditionUnsupported,
            .unsupportedMediaFeature,
            .invalidByteRangeResponse,
            .noVariantMatchesSelectionPolicy,
            .mediaResourceTooLarge,
            .totalDownloadTooLarge,
            .diskCapacityUnavailable,
            .insufficientDiskCapacity,
            .emptyOutput,
            .destinationAlreadyExists,
            .invalidDestination,
            .incompleteDownload,
            .offlineRenditionLimitExceeded,
            .invalidAES128Key,
            .aes128DecryptionFailed,
            .invalidOfflinePackage,
            .unsupportedOfflinePackageSchema:
            return false
        }
    }

    /// Whether the error is normally worth surfacing to an end user.
    public var isUserVisible: Bool {
        switch self {
        case .byteRangePlaylistUnsupported,
            .invalidDestination,
            .offlineRenditionLimitExceeded:
            return false
        case .invalidPlaylist,
            .invalidResponseStatus,
            .playlistTooLarge,
            .emptyMediaPlaylist,
            .livePlaylistUnsupported,
            .encryptedPlaylistUnsupported,
            .separateAudioRenditionUnsupported,
            .unsupportedMediaFeature,
            .invalidByteRangeResponse,
            .noVariantMatchesSelectionPolicy,
            .invalidMediaResponseStatus,
            .mediaResourceTooLarge,
            .totalDownloadTooLarge,
            .diskCapacityUnavailable,
            .insufficientDiskCapacity,
            .transferFailed,
            .emptyOutput,
            .destinationAlreadyExists,
            .destinationInUse,
            .incompleteDownload,
            .invalidAES128Key,
            .aes128DecryptionFailed,
            .invalidAES128KeyResponseStatus,
            .invalidOfflinePackage,
            .unsupportedOfflinePackageSchema:
            return true
        }
    }

    static func wrappingTransferFailure(_ error: any Error) -> Self {
        if let hlsError = error as? HLSDownloadError {
            return hlsError
        }
        return .transferFailed(SendableUnderlyingError(error))
    }

    static func internalTransferFailure(
        _ message: String,
        code: Int
    ) -> Self {
        .transferFailed(
            SendableUnderlyingError(
                domain: "com.innosquad.innonetwork.hls.internal",
                code: code,
                message: message
            )
        )
    }

    private static func isRetriableStatus(_ statusCode: Int) -> Bool {
        statusCode == 408
            || statusCode == 429
            || (500...599).contains(statusCode)
    }

    private static func isCancellation(
        _ error: SendableUnderlyingError
    ) -> Bool {
        error.domain == NSURLErrorDomain
            && error.code == NSURLErrorCancelled
    }
}

extension HLSUnsupportedMediaFeature {
    var diagnosticDescription: String {
        switch self {
        case .discontinuity:
            return hlsLocalized(
                "HLSDownloadError.feature.discontinuity"
            )
        case .gap:
            return hlsLocalized("HLSDownloadError.feature.gap")
        case .iFramesOnly:
            return hlsLocalized("HLSDownloadError.feature.iFramesOnly")
        case .multipleInitializationSections:
            return hlsLocalized(
                "HLSDownloadError.feature.multipleInitializationSections"
            )
        case .interstitialResource:
            return hlsLocalized(
                "HLSDownloadError.feature.interstitialResource"
            )
        case .dateRangeExternalResource:
            return hlsLocalized(
                "HLSDownloadError.feature.dateRangeExternalResource"
            )
        case .partialSegments:
            return hlsLocalized(
                "HLSDownloadError.feature.partialSegments"
            )
        case .preloadHintResource:
            return hlsLocalized(
                "HLSDownloadError.feature.preloadHintResource"
            )
        case .renditionReportResource:
            return hlsLocalized(
                "HLSDownloadError.feature.renditionReportResource"
            )
        case .deltaUpdate:
            return hlsLocalized(
                "HLSDownloadError.feature.deltaUpdate"
            )
        }
    }
}

extension HLSVariantSelectionPolicy {
    var diagnosticDescription: String {
        switch self {
        case .highestQuality:
            return hlsLocalized(
                "HLSDownloadError.selection.highestQuality"
            )
        case .lowestBandwidth:
            return hlsLocalized(
                "HLSDownloadError.selection.lowestBandwidth"
            )
        case .maximumResolution(let width, let height):
            return hlsLocalizedFormat(
                "HLSDownloadError.selection.maximumResolution",
                String(max(0, width)),
                String(max(0, height))
            )
        case .maximumBandwidth(let bandwidth):
            return hlsLocalizedFormat(
                "HLSDownloadError.selection.maximumBandwidth",
                String(max(0, bandwidth))
            )
        case .compatible:
            return hlsLocalized("HLSDownloadError.selection.compatible")
        }
    }
}

@inline(__always)
private func hlsLocalized(_ key: String) -> String {
    NSLocalizedString(
        key,
        bundle: .module,
        comment: "HLS download diagnostic"
    )
}

@inline(__always)
private func hlsLocalizedFormat(
    _ key: String,
    _ arguments: CVarArg...
) -> String {
    String(
        format: hlsLocalized(key),
        locale: Locale.current,
        arguments: arguments
    )
}
