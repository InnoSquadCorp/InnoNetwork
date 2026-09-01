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
    private let now: @Sendable () -> Date

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
            },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.resolver = resolver
        self.configuration = configuration
        self.keyPreloader = keyPreloader
        self.sleep = sleep
        self.keyPreloadSleep = keyPreloadSleep
        self.randomUnitInterval = randomUnitInterval
        self.now = now
    }

    /// Fetches one complete live-presentation snapshot.
    public func snapshot(
        from sourceURL: URL
    ) async throws -> HLSLivePlaylistSnapshot {
        let contentSteeringSession = makeContentSteeringSession()
        let entryURL = try HLSLiveReloadRequestBuilder.fullReloadURL(
            from: sourceURL
        )
        let presentation = try await resolvePresentation(
            from: entryURL,
            session: contentSteeringSession
        )
        let tuned = try await tuneIn(
            presentation.document,
            multivariantVariables:
                presentation.multivariantVariables
        )
        return try HLSLivePlaylistMerger.makeSnapshot(
            from: tuned.document,
            previous: nil,
            generation: 0,
            selectedVariant: presentation.selectedVariant,
            availableRenditions: presentation.renditions,
            pathwayID: presentation.pathwayID,
            multivariantVariables:
                presentation.multivariantVariables,
            reloadMode: tuned.reloadMode,
            measuredAt: now()
        )
    }

    func renditionSnapshot(
        from sourceURL: URL,
        multivariantVariables: [String: String],
        generation: Int
    ) async throws -> HLSLivePlaylistSnapshot {
        let entryURL = try HLSLiveReloadRequestBuilder.fullReloadURL(
            from: sourceURL
        )
        let document = try await resolveDocument(
            from: entryURL,
            purpose: .mediaPlaylist,
            multivariantVariables: multivariantVariables
        )
        let tuned = try await tuneIn(
            document,
            multivariantVariables: multivariantVariables
        )
        return try HLSLivePlaylistMerger.makeSnapshot(
            from: tuned.document,
            previous: nil,
            generation: generation,
            multivariantVariables: multivariantVariables,
            reloadMode: tuned.reloadMode,
            measuredAt: now()
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
        let contentSteeringSession = makeContentSteeringSession()
        let entryURL = try HLSLiveReloadRequestBuilder.fullReloadURL(
            from: sourceURL
        )
        let initialPresentation = try await resolvePresentation(
            from: entryURL,
            session: contentSteeringSession
        )
        let tuned = try await tuneIn(
            initialPresentation.document,
            multivariantVariables:
                initialPresentation.multivariantVariables
        )
        var pendingDocument: HLSLiveResolvedDocument? =
            tuned.document
        var requestURL =
            tuned.document.playlist.sourceURL
        var purpose = HLSRequestPurpose.livePlaylistReload
        var selectedVariant = initialPresentation.selectedVariant
        var availableRenditions = initialPresentation.renditions
        var pathwayID = initialPresentation.pathwayID
        var multivariantVariables =
            initialPresentation.multivariantVariables
        let pathwayCandidates =
            initialPresentation.pathwayCandidates
        var previous: HLSLivePlaylistSnapshot?
        var generation = 0
        var isFullReloadRecovery = false
        var reloadMode = tuned.reloadMode

        while true {
            try Task.checkCancellation()
            let document: HLSLiveResolvedDocument
            if let initialDocument = pendingDocument {
                document = initialDocument
                pendingDocument = nil
            } else {
                let tracksPathwayHealth = selectedVariant != nil
                if tracksPathwayHealth {
                    let admission = await contentSteeringSession.beginAttempt(
                        pathwayID: pathwayID,
                        phase: .mediaPlaylist,
                        resourceIndex: nil
                    )
                    if admission == .penalized {
                        await contentSteeringSession
                            .beginPenalizedFallbackAttempt(
                                pathwayID: pathwayID,
                                phase: .mediaPlaylist,
                                resourceIndex: nil
                            )
                    }
                }
                do {
                    document = try await resolveDocument(
                        from: requestURL,
                        purpose: purpose,
                        multivariantVariables:
                            multivariantVariables
                    )
                    if tracksPathwayHealth {
                        await contentSteeringSession.recordSuccess(
                            pathwayID: pathwayID,
                            phase: .mediaPlaylist,
                            resourceIndex: nil
                        )
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    let errorCode =
                        (error as? HLSDownloadError)?.code
                        ?? .transferFailed
                    if tracksPathwayHealth {
                        await contentSteeringSession.recordFailure(
                            pathwayID: pathwayID,
                            phase: .mediaPlaylist,
                            resourceIndex: nil,
                            errorCode: errorCode
                        )
                    }
                    guard
                        let recovery = try await resolveFallback(
                            after: previous,
                            failedPathwayID: pathwayID,
                            failureErrorCode: errorCode,
                            candidates: pathwayCandidates,
                            session: contentSteeringSession
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
                    reloadMode: reloadMode,
                    measuredAt: now()
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

    private func tuneIn(
        _ document: HLSLiveResolvedDocument,
        multivariantVariables: [String: String]
    ) async throws -> HLSLiveCDNTuneInResult {
        try await HLSLiveCDNTuneInCoordinator.resolve(
            initialDocument: document,
            settings: configuration.cdnTuneIn,
            now: now
        ) { url in
            try await resolveDocument(
                from: url,
                purpose: .livePlaylistReload,
                multivariantVariables: multivariantVariables
            )
        }
    }

    private func resolvePresentation(
        from sourceURL: URL,
        session: HLSContentSteeringSession
    ) async throws -> HLSLiveResolvedPresentation {
        do {
            return try await resolver.resolveLivePresentation(
                from: sourceURL,
                selectionPolicy:
                    configuration.variantSelectionPolicy,
                contentSteering: configuration.contentSteering,
                contentSteeringSession: session,
                requestTimeout:
                    configuration.reload.requestTimeout
            )
        } catch HLSLiveBridgeError.mediaPlaylistRequired {
            throw HLSLiveError.mediaPlaylistRequired
        }
    }

    private func resolveFallback(
        after snapshot: HLSLivePlaylistSnapshot?,
        failedPathwayID: String?,
        failureErrorCode: HLSDownloadErrorCode,
        candidates: [HLSLivePresentationCandidateRecord],
        session: HLSContentSteeringSession
    ) async throws -> (
        document: HLSLiveResolvedDocument,
        candidate: HLSLivePresentationCandidateRecord
    )? {
        for candidate in candidates {
            try Task.checkCancellation()
            guard candidate.pathwayID != failedPathwayID else {
                continue
            }
            let admission = await session.beginAttempt(
                pathwayID: candidate.pathwayID,
                phase: .mediaPlaylist,
                resourceIndex: nil
            )
            guard admission != .penalized else {
                continue
            }
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
                    requestTimeout:
                        configuration.reload.requestTimeout
                )
                await session.recordSuccess(
                    pathwayID: candidate.pathwayID,
                    phase: .mediaPlaylist,
                    resourceIndex: nil,
                    selection: HLSContentSteeringSession.Selection(
                        fromPathwayID: failedPathwayID,
                        reason:
                            admission == .recovered
                            ? .cooldownRecovery
                            : .pathwayFailure(
                                phase: .mediaPlaylist,
                                errorCode: failureErrorCode
                            )
                    )
                )
                return (document, candidate)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                await session.recordFailure(
                    pathwayID: candidate.pathwayID,
                    phase: .mediaPlaylist,
                    resourceIndex: nil,
                    errorCode: (error as? HLSDownloadError)?.code
                        ?? .transferFailed
                )
                continue
            }
        }
        return nil
    }

    private func makeContentSteeringSession()
        -> HLSContentSteeringSession
    {
        HLSContentSteeringSession(
            settings: configuration.contentSteering.resolvedSettings,
            now: now
        )
    }
}
