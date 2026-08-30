import Foundation
import InnoNetwork
import InnoNetworkHLS

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Resolves and reloads one HLS live presentation.
///
/// A media-playlist URL reloads directly. A multivariant URL first resolves a
/// deterministic variant and Content Steering pathway, then reloads the
/// selected media playlist.
public struct HLSLivePlaylistClient: Sendable {
    private let resolver: PlaylistResolver
    private let configuration: HLSLiveConfiguration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let keyPreloader: (any HLSLiveEncryptionKeyPreloading)?
    private let keyPreloadSleep: @Sendable (Duration) async throws -> Void
    private let randomUnitInterval: @Sendable () -> Double

    var resourceClient: HLSHTTPClient {
        resolver.client
    }

    /// Creates a live client backed by `URLSession.shared`.
    public init(
        configuration: HLSLiveConfiguration = .safeDefaults(),
        keyPreloader:
            (any HLSLiveEncryptionKeyPreloading)? = nil
    ) {
        self.init(
            resolver: PlaylistResolver(),
            configuration: configuration,
            keyPreloader: keyPreloader
        )
    }

    /// Creates a live client with caller-owned transport and typed HLS request
    /// policy.
    public init(
        session: URLSession,
        configuration: HLSLiveConfiguration = .safeDefaults(),
        requestContext: NetworkRequestContext = NetworkRequestContext(),
        requestPolicy: HLSRequestPolicy = HLSRequestPolicy(),
        keyPreloader:
            (any HLSLiveEncryptionKeyPreloading)? = nil
    ) {
        self.init(
            resolver: PlaylistResolver(
                session: session,
                requestContext: requestContext,
                requestPolicy: requestPolicy
            ),
            configuration: configuration,
            keyPreloader: keyPreloader
        )
    }

    init(
        resolver: PlaylistResolver,
        configuration: HLSLiveConfiguration,
        keyPreloader:
            (any HLSLiveEncryptionKeyPreloading)? = nil,
        sleep:
            @escaping @Sendable (Duration) async throws -> Void = {
                try await ContinuousClock().sleep(for: $0)
            },
        keyPreloadSleep:
            @escaping @Sendable (Duration) async throws -> Void = {
                try await ContinuousClock().sleep(for: $0)
            },
        randomUnitInterval:
            @escaping @Sendable () -> Double = {
                Double.random(in: 0...1)
            }
    ) {
        self.resolver = resolver
        self.configuration = configuration
        self.keyPreloader = keyPreloader
        self.sleep = sleep
        self.keyPreloadSleep = keyPreloadSleep
        self.randomUnitInterval = randomUnitInterval
    }

    /// Fetches one complete live-presentation snapshot.
    public func snapshot(
        from sourceURL: URL
    ) async throws -> HLSLivePlaylistSnapshot {
        let presentation = try await resolvePresentation(
            from: sourceURL
        )
        return try HLSLivePlaylistMerger.makeSnapshot(
            from: presentation.document,
            previous: nil,
            generation: 0,
            selectedVariant: presentation.selectedVariant,
            availableRenditions: presentation.renditions,
            pathwayID: presentation.pathwayID,
            multivariantVariables:
                presentation.multivariantVariables
        )
    }

    func renditionSnapshot(
        from sourceURL: URL,
        multivariantVariables: [String: String],
        generation: Int
    ) async throws -> HLSLivePlaylistSnapshot {
        let document = try await resolveDocument(
            from: sourceURL,
            purpose: .mediaPlaylist,
            multivariantVariables: multivariantVariables
        )
        return try HLSLivePlaylistMerger.makeSnapshot(
            from: document,
            previous: nil,
            generation: generation,
            multivariantVariables: multivariantVariables
        )
    }

    /// Starts a bounded-memory stream of live playlist responses.
    ///
    /// The first request uses the supplied media or multivariant URL.
    /// Subsequent requests prefer blocking reload and delta updates only when
    /// the server advertises them. A delta whose omitted history is unavailable
    /// triggers one full reload before the stream fails. Compatible
    /// Content Steering pathways may recover a failed media-playlist reload;
    /// stable variant identity is required and a matching rendition report
    /// provides the tune-in position. `EXT-X-ENDLIST` yields the final snapshot
    /// and then closes the stream.
    public func snapshots(
        from sourceURL: URL
    ) -> AsyncThrowingStream<HLSLivePlaylistSnapshot, Error> {
        let (stream, continuation) =
            AsyncThrowingStream<
                HLSLivePlaylistSnapshot,
                Error
            >.makeStream(
                bufferingPolicy: .bufferingNewest(1)
            )
        let client = self
        let keyPreloadCoordinator = keyPreloader.map {
            HLSLiveKeyPreloadCoordinator(
                preloader: $0,
                sleep: keyPreloadSleep,
                randomUnitInterval: randomUnitInterval
            )
        }
        let task = Task {
            do {
                try await client.run(
                    sourceURL: sourceURL,
                    continuation: continuation,
                    keyPreloadCoordinator:
                        keyPreloadCoordinator
                )
                await keyPreloadCoordinator?.cancelAll()
            } catch {
                await keyPreloadCoordinator?.cancelAll()
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in
            task.cancel()
        }
        return stream
    }

    private func run(
        sourceURL: URL,
        continuation:
            AsyncThrowingStream<
                HLSLivePlaylistSnapshot,
                Error
            >.Continuation,
        keyPreloadCoordinator:
            HLSLiveKeyPreloadCoordinator?
    ) async throws {
        let initialPresentation = try await resolvePresentation(
            from: sourceURL
        )
        var pendingDocument: HLSLiveResolvedDocument? =
            initialPresentation.document
        var requestURL =
            initialPresentation.document.playlist.sourceURL
        var purpose = HLSRequestPurpose.livePlaylistReload
        var selectedVariant = initialPresentation.selectedVariant
        var availableRenditions = initialPresentation.renditions
        var pathwayID = initialPresentation.pathwayID
        var multivariantVariables =
            initialPresentation.multivariantVariables
        var fallbackCandidates =
            initialPresentation.fallbackCandidates
        var previous: HLSLivePlaylistSnapshot?
        var generation = 0
        var isFullReloadRecovery = false
        var reloadMode = HLSLiveReloadMode.initial

        while true {
            try Task.checkCancellation()
            let document: HLSLiveResolvedDocument
            if let initialDocument = pendingDocument {
                document = initialDocument
                pendingDocument = nil
            } else {
                do {
                    document = try await resolveDocument(
                        from: requestURL,
                        purpose: purpose,
                        multivariantVariables:
                            multivariantVariables
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if selectedVariant != nil {
                        await configuration.contentSteering
                            .emitLivePlaylistFailure(
                                pathwayID: pathwayID,
                                errorCode: (error as? HLSDownloadError)?
                                    .code ?? .transferFailed
                            )
                    }
                    guard
                        let recovery = try await resolveFallback(
                            after: previous,
                            candidates: &fallbackCandidates
                        )
                    else {
                        throw error
                    }
                    document = recovery.document
                    selectedVariant = recovery.candidate.variant
                    availableRenditions =
                        recovery.candidate.renditions
                    pathwayID = recovery.candidate.pathwayID
                    multivariantVariables =
                        recovery.candidate.multivariantVariables
                    requestURL = document.playlist.sourceURL
                    isFullReloadRecovery = false
                    reloadMode = .contentSteeringRecovery
                }
            }
            let snapshot: HLSLivePlaylistSnapshot
            do {
                snapshot = try HLSLivePlaylistMerger.makeSnapshot(
                    from: document,
                    previous: previous,
                    generation: generation,
                    selectedVariant: selectedVariant,
                    availableRenditions: availableRenditions,
                    pathwayID: pathwayID,
                    multivariantVariables:
                        multivariantVariables,
                    reloadMode: reloadMode
                )
            } catch HLSLiveError.deltaBaseUnavailable {
                guard
                    !isFullReloadRecovery,
                    let previous
                else {
                    throw HLSLiveError.deltaBaseUnavailable
                }
                requestURL =
                    try HLSLiveReloadRequestBuilder
                    .fullReloadURL(
                        from: previous.playlist.sourceURL
                    )
                purpose = .livePlaylistReload
                isFullReloadRecovery = true
                reloadMode = .fullReloadRecovery
                continue
            }

            isFullReloadRecovery = false
            previous = snapshot
            await keyPreloadCoordinator?.update(
                after: snapshot
            )
            continuation.yield(snapshot)
            if snapshot.isEnded {
                continuation.finish()
                return
            }
            let reloadRequest =
                try HLSLiveReloadRequestBuilder.nextRequest(
                    after: snapshot,
                    settings: configuration.reload
                )
            if !reloadRequest.usesBlockingReload {
                try await sleep(
                    HLSLiveReloadRequestBuilder.pollingDelay(
                        after: snapshot,
                        settings: configuration.reload
                    )
                )
            }
            let (nextGeneration, overflow) =
                generation.addingReportingOverflow(1)
            guard !overflow else {
                throw HLSLiveError.sequenceOverflow
            }
            generation = nextGeneration
            requestURL = reloadRequest.url
            purpose = .livePlaylistReload
            reloadMode = reloadRequest.mode
        }
    }

    private func resolveDocument(
        from sourceURL: URL,
        purpose: HLSRequestPurpose,
        multivariantVariables: [String: String]? = nil
    ) async throws -> HLSLiveResolvedDocument {
        do {
            return try await resolver.resolveLiveDocument(
                from: sourceURL,
                purpose: purpose,
                requestTimeout:
                    configuration.reload.requestTimeout,
                multivariantVariables: multivariantVariables
            )
        } catch HLSLiveBridgeError.mediaPlaylistRequired {
            throw HLSLiveError.mediaPlaylistRequired
        }
    }

    private func resolvePresentation(
        from sourceURL: URL
    ) async throws -> HLSLiveResolvedPresentation {
        do {
            return try await resolver.resolveLivePresentation(
                from: sourceURL,
                selectionPolicy:
                    configuration.variantSelectionPolicy,
                contentSteering: configuration.contentSteering,
                requestTimeout:
                    configuration.reload.requestTimeout
            )
        } catch HLSLiveBridgeError.mediaPlaylistRequired {
            throw HLSLiveError.mediaPlaylistRequired
        }
    }

    private func resolveFallback(
        after snapshot: HLSLivePlaylistSnapshot?,
        candidates:
            inout [HLSLivePresentationCandidateRecord]
    ) async throws -> (
        document: HLSLiveResolvedDocument,
        candidate: HLSLivePresentationCandidateRecord
    )? {
        while !candidates.isEmpty {
            try Task.checkCancellation()
            let candidate = candidates.removeFirst()
            let requestURL: URL
            if let snapshot {
                requestURL =
                    try HLSLiveReloadRequestBuilder.tuneInURL(
                        for: candidate.variant.url,
                        using: snapshot
                    )
            } else {
                requestURL = candidate.variant.url
            }
            do {
                let document = try await resolver.resolveLiveFallback(
                    candidate,
                    from: requestURL,
                    contentSteering:
                        configuration.contentSteering,
                    requestTimeout:
                        configuration.reload.requestTimeout
                )
                return (document, candidate)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        return nil
    }
}
