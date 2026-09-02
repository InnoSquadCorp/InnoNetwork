#if canImport(AVFoundation) && !os(tvOS)
import Foundation
import InnoNetwork

/// Background-session behavior for system-managed HLS asset downloads.
public struct HLSAssetDownloadSessionPack: Sendable {
    /// The identifier used to reconnect to the background URL session.
    public let identifier: String

    /// Whether the system may defer transfers for favorable device conditions.
    public let isDiscretionary: Bool

    /// Whether transfers may use a cellular interface.
    public let allowsCellularAccess: Bool

    /// Whether transfers may use an interface marked as expensive.
    public let allowsExpensiveNetworkAccess: Bool

    /// Whether transfers may use an interface marked as constrained.
    public let allowsConstrainedNetworkAccess: Bool

    /// An optional shared app-group container for extension-owned sessions.
    public let sharedContainerIdentifier: String?

    /// Creates a system HLS download session pack.
    public init(
        identifier: String,
        isDiscretionary: Bool = false,
        allowsCellularAccess: Bool = true,
        allowsExpensiveNetworkAccess: Bool = true,
        allowsConstrainedNetworkAccess: Bool = true,
        sharedContainerIdentifier: String? = nil
    ) {
        self.identifier = identifier
        self.isDiscretionary = isDiscretionary
        self.allowsCellularAccess = allowsCellularAccess
        self.allowsExpensiveNetworkAccess =
            allowsExpensiveNetworkAccess
        self.allowsConstrainedNetworkAccess =
            allowsConstrainedNetworkAccess
        self.sharedContainerIdentifier = sharedContainerIdentifier
    }
}

/// Input for one system-managed HLS asset download.
public struct HLSAssetDownloadRequest: Sendable {
    /// An application-stable identifier copied to the URL task description.
    public let id: String

    /// The remote HLS URL.
    public let sourceURL: URL

    /// A localized title suitable for system storage and Live Activity UI.
    public let title: String

    /// Optional encoded artwork understood by the platform image decoder.
    public let artworkData: Data?

    /// Creates one asset download request.
    public init(
        id: String = UUID().uuidString,
        sourceURL: URL,
        title: String,
        artworkData: Data? = nil
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.title = title
        self.artworkData = artworkData
    }
}

/// Content retained by one system-managed HLS asset download.
public struct HLSAssetDownloadContentPack: Equatable, Sendable {
    /// Whether AVFoundation should retain interstitial assets for offline use.
    public let includesInterstitialAssets: Bool

    /// Creates an asset-content selection pack.
    public init(includesInterstitialAssets: Bool = false) {
        self.includesInterstitialAssets = includesInterstitialAssets
    }
}

/// A stable reference to an AVFoundation HLS asset download task.
public struct HLSAssetDownload: Hashable, Sendable {
    /// The application identifier stored in the underlying task description.
    public let id: String

    /// The task identifier assigned by the background URL session.
    public let taskIdentifier: Int

    let sessionIdentifier: String

    init(
        id: String,
        taskIdentifier: Int,
        sessionIdentifier: String
    ) {
        self.id = id
        self.taskIdentifier = taskIdentifier
        self.sessionIdentifier = sessionIdentifier
    }
}

/// Events emitted by a system-managed HLS asset download.
public enum HLSAssetDownloadEvent: Sendable {
    /// A best-effort completion fraction between zero and one.
    case progress(Double)

    /// A bounded, URL-free summary emitted by AVFoundation on OS 26 and newer.
    case downloadSummary(HLSAssetDownloadSummary)

    /// The system-managed URL where the asset must remain.
    case locationAvailable(URL)

    /// The asset completed at the system-managed URL.
    case completed(URL)

    /// The asset download failed with preserved Foundation classification.
    case failed(SendableUnderlyingError)

    /// The system or application cancelled the download.
    case cancelled
}

/// Failures produced before an AVFoundation asset task starts.
public enum HLSAssetDownloadSessionError: Error, Equatable, Sendable {
    /// A background session identifier was empty or only whitespace.
    case invalidSessionIdentifier

    /// Another live session already owns the same background identifier.
    case duplicateSessionIdentifier

    /// A shared-container identifier was empty or only whitespace.
    case invalidSharedContainerIdentifier

    /// A request identifier was empty or only whitespace.
    case invalidDownloadIdentifier

    /// A title was empty or only whitespace.
    case invalidTitle

    /// The source URL was not HTTPS.
    case insecureSourceURL

    /// The HTTPS source URL failed the shared network admission policy.
    case invalidSourceURL

    /// Encoded artwork exceeded the session's admission limit.
    case artworkTooLarge(limit: Int)

    /// Interstitial downloads require a supporting operating system and SDK.
    case interstitialAssetsUnavailable

    /// AVFoundation could not create a new asset task.
    case taskCreationFailed

    /// The referenced task is no longer present in the background session.
    case downloadNotFound

    /// The background session has begun invalidation.
    case sessionInvalidating

    /// The download belongs to another background session.
    case foreignSession
}

extension HLSAssetDownloadSessionError: LocalizedError {
    /// Localized human-readable summary of the configuration or lifecycle
    /// failure.
    public var errorDescription: String? {
        switch self {
        case .invalidSessionIdentifier:
            return assetLocalized(
                "HLSAssetDownloadSessionError.invalidSessionIdentifier"
            )
        case .duplicateSessionIdentifier:
            return assetLocalized(
                "HLSAssetDownloadSessionError.duplicateSessionIdentifier"
            )
        case .invalidSharedContainerIdentifier:
            return assetLocalized(
                "HLSAssetDownloadSessionError.invalidSharedContainerIdentifier"
            )
        case .invalidDownloadIdentifier:
            return assetLocalized(
                "HLSAssetDownloadSessionError.invalidDownloadIdentifier"
            )
        case .invalidTitle:
            return assetLocalized("HLSAssetDownloadSessionError.invalidTitle")
        case .insecureSourceURL:
            return assetLocalized(
                "HLSAssetDownloadSessionError.insecureSourceURL"
            )
        case .invalidSourceURL:
            return assetLocalized(
                "HLSAssetDownloadSessionError.invalidSourceURL"
            )
        case .artworkTooLarge(let limit):
            return assetLocalizedFormat(
                "HLSAssetDownloadSessionError.artworkTooLarge",
                String(limit)
            )
        case .interstitialAssetsUnavailable:
            return assetLocalized(
                "HLSAssetDownloadSessionError.interstitialAssetsUnavailable"
            )
        case .taskCreationFailed:
            return assetLocalized(
                "HLSAssetDownloadSessionError.taskCreationFailed"
            )
        case .downloadNotFound:
            return assetLocalized(
                "HLSAssetDownloadSessionError.downloadNotFound"
            )
        case .sessionInvalidating:
            return assetLocalized(
                "HLSAssetDownloadSessionError.sessionInvalidating"
            )
        case .foreignSession:
            return assetLocalized(
                "HLSAssetDownloadSessionError.foreignSession"
            )
        }
    }

    /// Localized, actionable next step for this failure.
    public var recoverySuggestion: String? {
        switch self {
        case .invalidSessionIdentifier,
            .invalidSharedContainerIdentifier,
            .invalidDownloadIdentifier,
            .invalidTitle:
            return assetLocalized(
                "HLSAssetDownloadSessionError.recovery.fixConfiguration"
            )
        case .duplicateSessionIdentifier:
            return assetLocalized(
                "HLSAssetDownloadSessionError.recovery.reuseSession"
            )
        case .insecureSourceURL, .invalidSourceURL:
            return assetLocalized(
                "HLSAssetDownloadSessionError.recovery.useHTTPSURL"
            )
        case .artworkTooLarge:
            return assetLocalized(
                "HLSAssetDownloadSessionError.recovery.reduceArtwork"
            )
        case .interstitialAssetsUnavailable:
            return assetLocalized(
                "HLSAssetDownloadSessionError.recovery.updateOS"
            )
        case .taskCreationFailed:
            return assetLocalized(
                "HLSAssetDownloadSessionError.recovery.retryTaskCreation"
            )
        case .downloadNotFound:
            return assetLocalized(
                "HLSAssetDownloadSessionError.recovery.refreshDownloads"
            )
        case .sessionInvalidating:
            return assetLocalized(
                "HLSAssetDownloadSessionError.recovery.createNewSession"
            )
        case .foreignSession:
            return assetLocalized(
                "HLSAssetDownloadSessionError.recovery.useOwningSession"
            )
        }
    }

    /// Conservative hint for UI code that needs a retry affordance.
    public var isRetriableHint: Bool {
        if case .taskCreationFailed = self {
            return true
        }
        return false
    }
}

@inline(__always)
private func assetLocalized(_ key: String) -> String {
    NSLocalizedString(
        key,
        bundle: .module,
        comment: "AVFoundation HLS session diagnostic"
    )
}

@inline(__always)
private func assetLocalizedFormat(
    _ key: String,
    _ arguments: CVarArg...
) -> String {
    String(
        format: assetLocalized(key),
        locale: Locale.current,
        arguments: arguments
    )
}
#endif
