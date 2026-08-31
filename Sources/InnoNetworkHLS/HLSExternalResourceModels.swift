import Foundation

/// Bounds optional metadata resources referenced by HLS playlists.
public struct HLSExternalResourcePack: Sendable {
    private let maximumSessionDataBytes: Int
    private let maximumCustomMediaSelectionEntryCount: Int
    private let maximumInterstitialAssetListBytes: Int
    private let maximumInterstitialAssetCount: Int
    private let maximumDateRangeResourceBytes: Int
    private let maximumScheduledDateRangeCount: Int
    private let maximumDateRangeScheduleDepth: Int
    private let requestTimeout: TimeInterval

    /// Creates finite resource limits.
    ///
    /// Byte limits are clamped to `1...2 MiB`, entry counts to `1...1,000`,
    /// schedule depth to `1...3`, and the request timeout to `1...300`
    /// seconds.
    public init(
        maximumSessionDataBytes: Int = 256 * 1_024,
        maximumCustomMediaSelectionEntryCount: Int = 256,
        maximumInterstitialAssetListBytes: Int = 256 * 1_024,
        maximumInterstitialAssetCount: Int = 100,
        maximumDateRangeResourceBytes: Int = 256 * 1_024,
        maximumScheduledDateRangeCount: Int = 100,
        maximumDateRangeScheduleDepth: Int = 3,
        requestTimeout: TimeInterval = 15
    ) {
        self.maximumSessionDataBytes = maximumSessionDataBytes
        self.maximumCustomMediaSelectionEntryCount =
            maximumCustomMediaSelectionEntryCount
        self.maximumInterstitialAssetListBytes =
            maximumInterstitialAssetListBytes
        self.maximumInterstitialAssetCount =
            maximumInterstitialAssetCount
        self.maximumDateRangeResourceBytes =
            maximumDateRangeResourceBytes
        self.maximumScheduledDateRangeCount =
            maximumScheduledDateRangeCount
        self.maximumDateRangeScheduleDepth =
            maximumDateRangeScheduleDepth
        self.requestTimeout = requestTimeout
    }

    var resolvedSettings: HLSExternalResourceSettings {
        HLSExternalResourceSettings(
            maximumSessionDataBytes: Self.boundedBytes(
                maximumSessionDataBytes
            ),
            maximumCustomMediaSelectionEntryCount: min(
                1_000,
                max(1, maximumCustomMediaSelectionEntryCount)
            ),
            maximumInterstitialAssetListBytes: Self.boundedBytes(
                maximumInterstitialAssetListBytes
            ),
            maximumInterstitialAssetCount: min(
                1_000,
                max(1, maximumInterstitialAssetCount)
            ),
            maximumDateRangeResourceBytes: Self.boundedBytes(
                maximumDateRangeResourceBytes
            ),
            maximumScheduledDateRangeCount: min(
                1_000,
                max(1, maximumScheduledDateRangeCount)
            ),
            maximumDateRangeScheduleDepth: min(
                3,
                max(1, maximumDateRangeScheduleDepth)
            ),
            requestTimeout: Self.boundedTimeout(requestTimeout)
        )
    }

    private static func boundedBytes(_ value: Int) -> Int {
        min(2 * 1_024 * 1_024, max(1, value))
    }

    private static func boundedTimeout(
        _ value: TimeInterval
    ) -> TimeInterval {
        guard value.isFinite else {
            return 15
        }
        return min(300, max(1, value))
    }
}

struct HLSExternalResourceSettings: Sendable {
    let maximumSessionDataBytes: Int
    let maximumCustomMediaSelectionEntryCount: Int
    let maximumInterstitialAssetListBytes: Int
    let maximumInterstitialAssetCount: Int
    let maximumDateRangeResourceBytes: Int
    let maximumScheduledDateRangeCount: Int
    let maximumDateRangeScheduleDepth: Int
    let requestTimeout: TimeInterval
}

/// Resolved content from one `EXT-X-SESSION-DATA` declaration.
public enum HLSSessionDataValue: Equatable, Sendable {
    /// An inline playlist value that required no network request.
    case string(String)

    /// A validated JSON document, preserving its original bytes.
    case json(Data)

    /// An application-defined raw resource.
    case raw(Data)
}

/// One asset returned by an Apple HLS interstitial source.
public struct HLSInterstitialAsset: Equatable, Sendable {
    /// The absolute HLS asset URL.
    public let url: URL

    /// Declared duration for an asset-list entry, or `nil` for a direct asset.
    public let duration: TimeInterval?

    init(url: URL, duration: TimeInterval?) {
        self.url = url
        self.duration = duration
    }
}

/// Bounded interstitial assets and their effective skip-control metadata.
public struct HLSInterstitialAssetResolution: Equatable, Sendable {
    /// Assets in playback order.
    public let assets: [HLSInterstitialAsset]

    /// Playlist metadata after applying an asset-list `SKIP-CONTROL` override.
    public let skipControl: HLSInterstitialSkipControl?

    init(
        assets: [HLSInterstitialAsset],
        skipControl: HLSInterstitialSkipControl?
    ) {
        self.assets = assets
        self.skipControl = skipControl
    }
}

/// Failures produced while loading or validating an external HLS resource.
public enum HLSExternalResourceError: Error, Equatable, Sendable {
    /// The HTTP response was not successful.
    case invalidResponseStatus(Int)

    /// The resource exceeded its configured byte boundary.
    case responseTooLarge(limit: Int)

    /// A JSON Session Data resource was malformed.
    case invalidSessionDataJSON

    /// The reserved Custom Media Selection Session Data declaration was
    /// malformed.
    case invalidCustomMediaSelectionDeclaration

    /// A Custom Media Selection Scheme did not match Apple's JSON schema.
    case invalidCustomMediaSelectionScheme

    /// A Custom Media Selection Scheme exceeded its configured entry limit.
    case tooManyCustomMediaSelectionEntries(limit: Int)

    /// An interstitial asset list did not match Apple's schema.
    case invalidInterstitialAssetList

    /// An asset list exceeded its configured entry boundary.
    case tooManyInterstitialAssets(limit: Int)

    /// A Date Range did not satisfy the preload contract.
    case invalidDateRangePreload

    /// A Date Range Schedule JSON document was malformed.
    case invalidDateRangeSchedule

    /// A schedule exceeded its configured recursive depth.
    case dateRangeScheduleDepthExceeded(limit: Int)

    /// A schedule recursively referenced an ancestor resource.
    case dateRangeScheduleCycle

    /// Scheduled Date Range identifiers were not unique.
    case duplicateScheduledDateRangeIdentifier

    /// A schedule exceeded its configured total entry boundary.
    case tooManyScheduledDateRanges(limit: Int)

    /// A live-join schedule offset was negative or nonfinite.
    case invalidDateRangeScheduleStartOffset
}

extension HLSExternalResourceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidResponseStatus(let statusCode):
            return "The external HLS resource returned HTTP \(statusCode)."
        case .responseTooLarge(let limit):
            return "The external HLS resource exceeded the \(limit)-byte limit."
        case .invalidSessionDataJSON:
            return "The HLS Session Data resource is not valid JSON."
        case .invalidCustomMediaSelectionDeclaration:
            return "The HLS Custom Media Selection declaration is invalid."
        case .invalidCustomMediaSelectionScheme:
            return "The HLS Custom Media Selection Scheme is malformed."
        case .tooManyCustomMediaSelectionEntries(let limit):
            return "The HLS Custom Media Selection Scheme exceeds the \(limit)-entry limit."
        case .invalidInterstitialAssetList:
            return "The HLS interstitial asset list is malformed."
        case .tooManyInterstitialAssets(let limit):
            return "The HLS interstitial asset list exceeds the \(limit)-asset limit."
        case .invalidDateRangePreload:
            return "The HLS Date Range preload metadata is invalid or inactive."
        case .invalidDateRangeSchedule:
            return "The HLS Date Range Schedule is malformed."
        case .dateRangeScheduleDepthExceeded(let limit):
            return "The HLS Date Range Schedule exceeds the \(limit)-level nesting limit."
        case .dateRangeScheduleCycle:
            return "The HLS Date Range Schedule contains a recursive resource cycle."
        case .duplicateScheduledDateRangeIdentifier:
            return "The HLS Date Range Schedule contains a duplicate identifier."
        case .tooManyScheduledDateRanges(let limit):
            return "The HLS Date Range Schedule exceeds the \(limit)-entry limit."
        case .invalidDateRangeScheduleStartOffset:
            return "The HLS Date Range Schedule start offset is invalid."
        }
    }
}
