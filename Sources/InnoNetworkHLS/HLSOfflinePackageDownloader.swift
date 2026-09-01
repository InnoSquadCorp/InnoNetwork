import Foundation
import InnoNetwork

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Creates atomic, self-contained HLS directories with selected external
/// audio and subtitle renditions.
///
/// Media resources remain separate and local media playlists are rewritten to
/// reference them. This preserves each rendition's HLS timeline instead of
/// pretending independently timed tracks can be concatenated into one file.
public struct HLSOfflinePackageDownloader: Sendable {
    private let operation: HLSOfflinePackageOperation

    /// Creates a downloader with conservative defaults and `URLSession.shared`.
    public init() {
        self.init(configuration: .safeDefaults())
    }

    /// Creates a configured downloader backed by `URLSession.shared`.
    public init(
        configuration: HLSOfflinePackageConfiguration
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

    /// Creates a downloader with caller-owned transport policy.
    public init(
        session: URLSession,
        configuration: HLSOfflinePackageConfiguration =
            .safeDefaults(),
        requestContext: NetworkRequestContext =
            NetworkRequestContext(),
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

    /// Creates a downloader with purpose-aware request policy.
    public init(
        session: URLSession,
        configuration: HLSOfflinePackageConfiguration =
            .safeDefaults(),
        requestContext: NetworkRequestContext =
            NetworkRequestContext(),
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

    package init(
        client: HLSHTTPClient,
        configuration: HLSOfflinePackageConfiguration
    ) {
        self.init(
            client: client,
            configuration: configuration,
            diskCapacityChecker: HLSDiskCapacityChecker(),
            clock: SystemClock()
        )
    }

    init(
        client: HLSHTTPClient,
        configuration: HLSOfflinePackageConfiguration,
        diskCapacityChecker: HLSDiskCapacityChecker =
            HLSDiskCapacityChecker(),
        clock: any InnoNetworkClock = SystemClock()
    ) {
        self.operation = HLSOfflinePackageOperation(
            client: client,
            configuration: configuration,
            diskCapacityChecker: diskCapacityChecker,
            clock: clock
        )
    }

    /// Resolves the selected primary and rendition playlists without fetching
    /// media resources or creating files.
    public func prepare(
        sourceURL: URL
    ) async throws -> HLSOfflinePackagePreparation {
        try await operation.prepare(sourceURL: sourceURL)
    }

    /// Starts creating an offline HLS package at a new directory.
    ///
    /// The destination must not exist. Work is performed in a hidden sibling
    /// directory and committed with one final rename.
    public func download(
        sourceURL: URL,
        destinationDirectoryURL: URL
    ) -> AsyncStream<HLSOfflinePackageEvent> {
        let (stream, continuation) =
            AsyncStream<HLSOfflinePackageEvent>.makeStream(
                bufferingPolicy: .bufferingNewest(16)
            )
        let executor = operation
        let task = Task {
            await executor.perform(
                sourceURL: sourceURL,
                destinationDirectoryURL:
                    destinationDirectoryURL,
                continuation: continuation
            )
        }
        continuation.onTermination = { _ in
            task.cancel()
        }
        return stream
    }

    /// Creates and atomically commits an offline HLS package.
    public func downloadPackage(
        sourceURL: URL,
        destinationDirectoryURL: URL
    ) async throws -> HLSOfflinePackageReceipt {
        let outcome = await operation.execute(
            sourceURL: sourceURL,
            destinationDirectoryURL: destinationDirectoryURL,
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
}
