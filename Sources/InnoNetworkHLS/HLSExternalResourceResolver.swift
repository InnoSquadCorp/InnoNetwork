import Foundation
import InnoNetwork

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Resolves bounded resources referenced by HLS metadata.
public struct HLSExternalResourceResolver: Sendable {
    private let loader: HLSExternalResourceLoader
    private let settings: HLSExternalResourceSettings
    private let dateRangeScheduleResolver: HLSDateRangeScheduleResolver

    /// Creates a resolver backed by `URLSession.shared`.
    public init(
        configuration: HLSExternalResourcePack =
            HLSExternalResourcePack()
    ) {
        self.init(
            client: HLSHTTPClient(
                session: .shared,
                requestContext: NetworkRequestContext(),
                requestAdapter: { $0 }
            ),
            configuration: configuration
        )
    }

    /// Creates a resolver with caller-owned transport and typed request policy.
    public init(
        session: URLSession,
        configuration: HLSExternalResourcePack =
            HLSExternalResourcePack(),
        requestContext: NetworkRequestContext =
            NetworkRequestContext(),
        requestPolicy: HLSRequestPolicy = HLSRequestPolicy()
    ) {
        self.init(
            client: HLSHTTPClient(
                session: session,
                requestContext: requestContext,
                requestPolicy: requestPolicy
            ),
            configuration: configuration
        )
    }

    init(
        client: HLSHTTPClient,
        configuration: HLSExternalResourcePack
    ) {
        let settings = configuration.resolvedSettings
        self.settings = settings
        let loader = HLSExternalResourceLoader(
            client: client,
            requestTimeout: settings.requestTimeout
        )
        self.loader = loader
        self.dateRangeScheduleResolver =
            HLSDateRangeScheduleResolver(
                loader: loader,
                settings: settings
            )
    }

    /// Resolves inline, JSON, or raw `EXT-X-SESSION-DATA` content.
    public func resolveSessionData(
        _ sessionData: HLSSessionData
    ) async throws -> HLSSessionDataValue {
        switch sessionData.content {
        case .value(let value):
            return .string(value)
        case .remote(let url, let format):
            let data = try await loader.load(
                from: url,
                purpose: .sessionData,
                accept: format == .json
                    ? "application/json"
                    : "application/octet-stream",
                maximumBytes:
                    settings.maximumSessionDataBytes
            )
            switch format {
            case .json:
                guard
                    (try? JSONSerialization.jsonObject(
                        with: data,
                        options: [.fragmentsAllowed]
                    )) != nil
                else {
                    throw HLSExternalResourceError
                        .invalidSessionDataJSON
                }
                return .json(data)
            case .raw:
                return .raw(data)
            }
        }
    }

    /// Resolves the playlist's Apple Custom Media Selection Scheme.
    ///
    /// Returns `nil` when the reserved Session Data identifier is absent.
    public func resolveCustomMediaSelection(
        in playlist: HLSPlaylist
    ) async throws -> HLSCustomMediaSelectionScheme? {
        let declarations = playlist.sessionData.filter {
            $0.dataID
                == HLSCustomMediaSelectionScheme.sessionDataID
        }
        guard !declarations.isEmpty else {
            return nil
        }
        guard
            declarations.count == 1,
            let declaration = declarations.first,
            declaration.language == nil,
            case .remote(let url, format: .json) =
                declaration.content
        else {
            throw HLSExternalResourceError
                .invalidCustomMediaSelectionDeclaration
        }
        let data = try await loader.load(
            from: url,
            purpose: .customMediaSelectionScheme,
            accept: "application/json",
            maximumBytes: settings.maximumSessionDataBytes
        )
        return try HLSCustomMediaSelectionDecoder.decode(
            data,
            maximumEntryCount:
                settings.maximumCustomMediaSelectionEntryCount
        )
    }

    /// Resolves a direct interstitial asset or Apple's `ASSETS` JSON list.
    public func resolveInterstitialAssets(
        _ interstitial: HLSInterstitial
    ) async throws -> [HLSInterstitialAsset] {
        switch interstitial.source {
        case .asset(let url):
            return [
                HLSInterstitialAsset(
                    url: url,
                    duration: nil
                )
            ]
        case .assetList(let url):
            let data = try await loader.load(
                from: url,
                purpose: .interstitialAssetList,
                accept: "application/json",
                maximumBytes:
                    settings.maximumInterstitialAssetListBytes
            )
            return try HLSInterstitialAssetListDecoder.decode(
                data,
                maximumAssetCount:
                    settings.maximumInterstitialAssetCount
            )
        }
    }

    /// Loads one eligible `com.apple.hls.preload` resource.
    public func preloadDateRangeResource(
        _ dateRange: HLSDateRange
    ) async throws -> HLSPreloadedDateRangeResource {
        try await dateRangeScheduleResolver.preload(dateRange)
    }

    /// Resolves a bounded Date Range Schedule, including nested schedules.
    ///
    /// Supply playlist-level identifiers through `occupiedDateRangeIDs` so
    /// scheduled entries cannot collide with ranges already in the playlist.
    public func resolveDateRangeSchedule(
        _ schedule: HLSDateRange,
        preloadedResource: HLSPreloadedDateRangeResource? = nil,
        startOffset: TimeInterval? = nil,
        occupiedDateRangeIDs: Set<String> = []
    ) async throws -> HLSDateRangeSchedule {
        try await dateRangeScheduleResolver.resolve(
            schedule,
            preloadedResource: preloadedResource,
            startOffset: startOffset,
            occupiedDateRangeIDs: occupiedDateRangeIDs
        )
    }
}
