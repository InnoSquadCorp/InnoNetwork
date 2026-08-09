import Foundation
import InnoNetwork

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Downloads non-DRM HLS VOD with bounded per-resource transfers.
///
/// The downloader assembles MPEG transport-stream segments or fragmented MP4
/// resources in playlist order. Identity-format AES-128-CBC segments are
/// decrypted before assembly. It doesn't transcode media. Live playlists,
/// SAMPLE-AES/FairPlay media, and unsupported timeline layouts fail with a
/// typed error so applications can choose a specialized backend when needed.
public struct HLSDownloader: Sendable {
    private let operation: HLSDownloadOperation

    /// Creates an HLS VOD downloader backed by `URLSession.shared`.
    public init() {
        self.init(configuration: .safeDefaults())
    }

    /// Creates a configured HLS VOD downloader backed by `URLSession.shared`.
    public init(
        configuration: HLSDownloadConfiguration
    ) {
        let client = HLSHTTPClient(
            session: .shared,
            requestContext: NetworkRequestContext(),
            requestAdapter: { $0 }
        )
        self.init(
            client: client,
            configuration: configuration
        )
    }

    /// Creates an HLS VOD downloader with caller-owned transport policy.
    ///
    /// - Parameters:
    ///   - session: The URL session used for playlist and media requests.
    ///   - requestContext: InnoNetwork trust, redirect, and metrics policy
    ///     applied to every request. Its event observers receive media retry
    ///     scheduling and terminal-cancellation events.
    ///   - requestAdapter: An async adapter for authentication or custom
    ///     request headers.
    public init(
        session: URLSession,
        configuration: HLSDownloadConfiguration = .safeDefaults(),
        requestContext: NetworkRequestContext = NetworkRequestContext(),
        requestAdapter:
            @escaping @Sendable (URLRequest) async throws -> URLRequest = {
                $0
            }
    ) {
        let client = HLSHTTPClient(
            session: session,
            requestContext: requestContext,
            requestAdapter: requestAdapter
        )
        self.init(
            client: client,
            configuration: configuration
        )
    }

    /// Creates an HLS VOD downloader with purpose-aware request policy.
    ///
    /// Use the policy context to apply different authentication to playlists,
    /// media payloads, AES keys, and Content Steering manifests without
    /// deriving resource type from a URL.
    public init(
        session: URLSession,
        configuration: HLSDownloadConfiguration = .safeDefaults(),
        requestContext: NetworkRequestContext = NetworkRequestContext(),
        requestPolicy: HLSRequestPolicy
    ) {
        let client = HLSHTTPClient(
            session: session,
            requestContext: requestContext,
            requestPolicy: requestPolicy
        )
        self.init(
            client: client,
            configuration: configuration
        )
    }

    init(
        client: HLSHTTPClient,
        configuration: HLSDownloadConfiguration,
        diskCapacityChecker: HLSDiskCapacityChecker =
            HLSDiskCapacityChecker(),
        clock: any InnoNetworkClock = SystemClock()
    ) {
        self.operation = HLSDownloadOperation(
            client: client,
            configuration: configuration,
            diskCapacityChecker: diskCapacityChecker,
            clock: clock
        )
    }

    /// Resolves and validates the media that the current policy would select.
    ///
    /// This method performs playlist requests but does not create files,
    /// reserve a destination, or fetch media bytes. The returned snapshot is
    /// advisory: a later download resolves the playlists again to avoid
    /// silently executing stale network metadata.
    public func prepare(
        sourceURL: URL
    ) async throws -> HLSDownloadPreparation {
        try await operation.prepare(sourceURL: sourceURL)
    }

    /// Starts downloading an HLS VOD stream to a requested file.
    ///
    /// Use the playlist's ``HLSPlaylist/mediaContainer`` file extension for
    /// `destinationURL`. The returned stream starts work immediately and owns
    /// its partial-file lifecycle. With automatic resume enabled, interrupted
    /// output remains at a validated resource boundary for the next call.
    public func download(
        sourceURL: URL,
        destinationURL: URL
    ) -> AsyncStream<HLSDownloadEvent> {
        let (stream, continuation) =
            AsyncStream<HLSDownloadEvent>.makeStream(
                bufferingPolicy: .bufferingNewest(16)
            )

        let executor = operation
        let task = Task {
            await executor.perform(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                continuation: continuation
            )
        }
        continuation.onTermination = { _ in
            task.cancel()
        }
        return stream
    }

    /// Downloads an HLS VOD stream and returns its committed receipt.
    ///
    /// Use this one-shot form when progress events are unnecessary but the
    /// selected variant, media container, byte count, or resume outcome is
    /// useful to the caller.
    public func downloadReceipt(
        sourceURL: URL,
        destinationURL: URL
    ) async throws -> HLSDownloadReceipt {
        let outcome = await operation.execute(
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            onProgress: { _ in }
        )
        switch outcome {
        case .completed(let receipt):
            return receipt
        case .failed(let error):
            throw error
        case .cancelled:
            throw CancellationError()
        }
    }

    /// Downloads an HLS VOD stream and returns the committed destination.
    ///
    /// Use this convenience when progress events and receipt metadata are not
    /// needed. It preserves task cancellation and throws typed terminal
    /// failures as ``HLSDownloadError``.
    public func downloadFile(
        sourceURL: URL,
        destinationURL: URL
    ) async throws -> URL {
        try await downloadReceipt(
            sourceURL: sourceURL,
            destinationURL: destinationURL
        ).destinationURL
    }
}
