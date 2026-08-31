import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The semantic purpose of one HLS network request.
///
/// A request policy receives this value before transport so authentication
/// and headers can vary by HLS resource without inspecting URL suffixes.
public enum HLSRequestPurpose: Equatable, Sendable {
    /// The entry document supplied by the caller.
    case entryPlaylist

    /// A selected variant, rendition, or trick-play media playlist.
    case mediaPlaylist

    /// A subsequent media-playlist request driven by a live reload loop.
    case livePlaylistReload

    /// A media segment, initialization map, or other media payload.
    case mediaResource

    /// A speculative media resource announced by `EXT-X-PRELOAD-HINT`.
    case mediaPreloadHint

    /// An identity-format AES-128 key.
    case encryptionKey

    /// A Content Steering JSON manifest.
    case contentSteeringManifest

    /// A remote `EXT-X-SESSION-DATA` JSON or raw resource.
    case sessionData

    /// An Apple Custom Media Selection Scheme JSON resource.
    case customMediaSelectionScheme

    /// An Apple HLS interstitial asset-list JSON resource.
    case interstitialAssetList

    /// A resource announced by `com.apple.hls.preload`.
    case dateRangePreloadResource

    /// An Apple HLS Date Range Schedule JSON resource.
    case dateRangeSchedule
}

/// Value-redacted metadata supplied to HLS request policy and observers.
public struct HLSRequestContext: Equatable, Sendable {
    /// The stable identifier shared by retries of one logical request.
    public let requestID: UUID

    /// The semantic purpose of the request.
    public let purpose: HLSRequestPurpose

    /// The ordered transfer-plan index for media resources, when applicable.
    public let resourceIndex: Int?

    /// The zero-based retry index.
    public let retryIndex: Int

    init(
        requestID: UUID,
        purpose: HLSRequestPurpose,
        resourceIndex: Int?,
        retryIndex: Int
    ) {
        self.requestID = requestID
        self.purpose = purpose
        self.resourceIndex = resourceIndex
        self.retryIndex = retryIndex
    }
}

/// A stable, payload-free classification for a pre-response HLS request
/// failure.
public enum HLSRequestFailure: Equatable, Sendable {
    /// The caller-provided request adapter failed.
    case adaptation

    /// The adapted URL was rejected by secure network admission.
    case urlAdmission

    /// The transport failed before response headers were available.
    case transport

    /// The request was cancelled before response headers were available.
    case cancellation
}

/// A value-redacted event emitted at the HLS request boundary.
///
/// Events never contain URLs, headers, query values, bodies, or arbitrary
/// error messages. Core ``InnoNetwork/NetworkEventObserving`` remains the
/// source for complete transport lifecycle and metrics events.
public enum HLSRequestEvent: Equatable, Sendable {
    /// Request adaptation is about to begin.
    case requestStarted(HLSRequestContext)

    /// Response headers became available.
    case responseReceived(
        HLSRequestContext,
        statusCode: Int?
    )

    /// The request failed before response headers became available.
    case requestFailed(
        HLSRequestContext,
        failure: HLSRequestFailure
    )
}

/// Receives ordered, value-redacted HLS request events.
public protocol HLSRequestEventObserving: Sendable {
    /// Handles one event before the request pipeline continues.
    func hlsRequestDidEmit(_ event: HLSRequestEvent) async
}

/// Applies purpose-aware request adaptation and HLS-specific observation.
///
/// The policy is immutable and shared by playlist, media, AES-key, Content
/// Steering, Session Data, Custom Media Selection, interstitial, and Date
/// Range resource requests. The adapter may change headers and other request
/// properties, but its resulting URL still passes through InnoNetwork's
/// secure URL admission.
public struct HLSRequestPolicy: Sendable {
    private let adapter: @Sendable (URLRequest, HLSRequestContext) async throws -> URLRequest
    private let eventObservers: [any HLSRequestEventObserving]

    /// Creates a purpose-aware policy.
    ///
    /// Observer delivery is ordered and applies backpressure to the request
    /// boundary. Keep handlers short and hand off expensive export work.
    public init(
        eventObservers: [any HLSRequestEventObserving] = [],
        adapter:
            @escaping @Sendable (
                URLRequest,
                HLSRequestContext
            ) async throws -> URLRequest = { request, _ in request }
    ) {
        self.adapter = adapter
        self.eventObservers = eventObservers
    }

    func adapt(
        _ request: URLRequest,
        context: HLSRequestContext
    ) async throws -> URLRequest {
        try await adapter(request, context)
    }

    func emit(_ event: HLSRequestEvent) async {
        for observer in eventObservers {
            await observer.hlsRequestDidEmit(event)
        }
    }
}
