#if canImport(AVFoundation) && !os(tvOS)
import AVFoundation
import Foundation
import InnoNetwork
import os

/// Owns one reconnectable AVFoundation background HLS download session.
///
/// Keep this object alive for the lifetime of the matching background
/// session identifier. Downloaded assets must remain at the URLs delivered
/// by ``HLSAssetDownloadEvent/locationAvailable(_:)``.
@available(macOS 12.0, iOS 15.0, watchOS 10.0, visionOS 1.0, *)
public final class HLSAssetDownloadSession: Sendable {
    private static let maximumArtworkBytes = 10 * 1_024 * 1_024

    private struct LifecycleState {
        var isInvalidating = false
    }

    private let configuration: HLSAssetDownloadSessionPack
    private let session: AVAssetDownloadURLSession
    private let eventHub: HLSAssetDownloadEventHub
    private let backgroundCompletions: HLSAssetDownloadBackgroundCompletionStore
    private let invalidationGate: HLSAssetDownloadInvalidationGate
    private let sessionIdentifierLease: HLSAssetDownloadSessionIdentifierLease
    private let lifecycle = OSAllocatedUnfairLock(
        initialState: LifecycleState()
    )

    /// Creates or reconnects to a background AVFoundation HLS session.
    public init(
        configuration: HLSAssetDownloadSessionPack
    ) throws {
        let identifier = configuration.identifier.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !identifier.isEmpty else {
            throw HLSAssetDownloadSessionError.invalidSessionIdentifier
        }
        if let sharedContainerIdentifier =
            configuration.sharedContainerIdentifier
        {
            guard
                !sharedContainerIdentifier.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
            else {
                throw HLSAssetDownloadSessionError
                    .invalidSharedContainerIdentifier
            }
        }
        guard
            HLSAssetDownloadSessionIdentifierRegistry.acquire(
                identifier
            )
        else {
            throw HLSAssetDownloadSessionError.duplicateSessionIdentifier
        }
        let sessionIdentifierLease =
            HLSAssetDownloadSessionIdentifierLease(
                identifier: identifier
            )

        let eventHub = HLSAssetDownloadEventHub()
        let backgroundCompletions =
            HLSAssetDownloadBackgroundCompletionStore()
        let invalidationGate = HLSAssetDownloadInvalidationGate()
        let delegate = HLSAssetDownloadDelegate(
            eventHub: eventHub,
            backgroundCompletions: backgroundCompletions,
            invalidationGate: invalidationGate,
            onInvalidation: sessionIdentifierLease.release
        )
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.qualityOfService = .utility

        let urlConfiguration =
            URLSessionConfiguration.background(
                withIdentifier: identifier
            )
        urlConfiguration.isDiscretionary =
            configuration.isDiscretionary
        urlConfiguration.allowsCellularAccess =
            configuration.allowsCellularAccess
        urlConfiguration.allowsExpensiveNetworkAccess =
            configuration.allowsExpensiveNetworkAccess
        urlConfiguration.allowsConstrainedNetworkAccess =
            configuration.allowsConstrainedNetworkAccess
        urlConfiguration.sharedContainerIdentifier =
            configuration.sharedContainerIdentifier
        urlConfiguration.sessionSendsLaunchEvents = true

        self.configuration = HLSAssetDownloadSessionPack(
            identifier: identifier,
            isDiscretionary: configuration.isDiscretionary,
            allowsCellularAccess: configuration.allowsCellularAccess,
            allowsExpensiveNetworkAccess:
                configuration.allowsExpensiveNetworkAccess,
            allowsConstrainedNetworkAccess:
                configuration.allowsConstrainedNetworkAccess,
            sharedContainerIdentifier:
                configuration.sharedContainerIdentifier
        )
        self.eventHub = eventHub
        self.backgroundCompletions = backgroundCompletions
        self.invalidationGate = invalidationGate
        self.sessionIdentifierLease = sessionIdentifierLease
        self.session = AVAssetDownloadURLSession(
            configuration: urlConfiguration,
            assetDownloadDelegate: delegate,
            delegateQueue: delegateQueue
        )
    }

    /// Creates and starts a system-managed HLS download.
    ///
    /// The synchronous configuration closure is main-actor isolated because
    /// `AVAssetDownloadConfiguration` is intentionally non-Sendable. Use it
    /// to provide media selections, variant qualifiers, or interstitial
    /// policy before AVFoundation copies the configuration.
    @MainActor
    public func start(
        _ request: HLSAssetDownloadRequest,
        configure:
            (AVAssetDownloadConfiguration) throws -> Void = { _ in }
    ) throws -> HLSAssetDownload {
        try start(
            request,
            content: HLSAssetDownloadContentPack(),
            startsImmediately: true,
            configure: configure
        )
    }

    /// Creates and starts a download with typed offline-content selection.
    @MainActor
    public func start(
        _ request: HLSAssetDownloadRequest,
        content: HLSAssetDownloadContentPack,
        configure:
            (AVAssetDownloadConfiguration) throws -> Void = { _ in }
    ) throws -> HLSAssetDownload {
        try start(
            request,
            content: content,
            startsImmediately: true,
            configure: configure
        )
    }

    @MainActor
    func start(
        _ request: HLSAssetDownloadRequest,
        content: HLSAssetDownloadContentPack =
            HLSAssetDownloadContentPack(),
        startsImmediately: Bool,
        configure:
            (AVAssetDownloadConfiguration) throws -> Void
    ) throws -> HLSAssetDownload {
        let asset = AVURLAsset(url: request.sourceURL)
        return try makeDownload(
            asset: asset,
            id: request.id,
            title: request.title,
            artworkData: request.artworkData,
            content: content,
            startsImmediately: startsImmediately,
            configure: configure
        )
    }

    /// Creates and starts a system-managed download for a caller-owned asset.
    ///
    /// Use this overload when the application must attach an
    /// `AVContentKeySession` or configure other asset-level behavior first.
    @MainActor
    public func start(
        asset: AVURLAsset,
        id: String = UUID().uuidString,
        title: String,
        artworkData: Data? = nil,
        configure:
            (AVAssetDownloadConfiguration) throws -> Void = { _ in }
    ) throws -> HLSAssetDownload {
        try makeDownload(
            asset: asset,
            id: id,
            title: title,
            artworkData: artworkData,
            content: HLSAssetDownloadContentPack(),
            startsImmediately: true,
            configure: configure
        )
    }

    /// Starts a caller-owned asset with typed offline-content selection.
    @MainActor
    public func start(
        asset: AVURLAsset,
        id: String = UUID().uuidString,
        title: String,
        artworkData: Data? = nil,
        content: HLSAssetDownloadContentPack,
        configure:
            (AVAssetDownloadConfiguration) throws -> Void = { _ in }
    ) throws -> HLSAssetDownload {
        try makeDownload(
            asset: asset,
            id: id,
            title: title,
            artworkData: artworkData,
            content: content,
            startsImmediately: true,
            configure: configure
        )
    }

    @MainActor
    private func makeDownload(
        asset: AVURLAsset,
        id: String,
        title: String,
        artworkData: Data?,
        content: HLSAssetDownloadContentPack,
        startsImmediately: Bool,
        configure:
            (AVAssetDownloadConfiguration) throws -> Void
    ) throws -> HLSAssetDownload {
        try Self.validate(
            id: id,
            sourceURL: asset.url,
            title: title,
            artworkData: artworkData
        )
        let downloadConfiguration = AVAssetDownloadConfiguration(
            asset: asset,
            title: title
        )
        downloadConfiguration.artworkData = artworkData
        try Self.apply(content, to: downloadConfiguration)
        try configure(downloadConfiguration)
        guard !lifecycle.withLock({ $0.isInvalidating }) else {
            throw HLSAssetDownloadSessionError.sessionInvalidating
        }
        let task = session.makeAssetDownloadTask(
            downloadConfiguration: downloadConfiguration
        )
        guard task.state == .suspended else {
            task.cancel()
            throw HLSAssetDownloadSessionError.taskCreationFailed
        }
        task.taskDescription = id
        let download = makeDownload(task)
        if startsImmediately {
            task.resume()
        }
        return download
    }

    @MainActor
    private static func apply(
        _ content: HLSAssetDownloadContentPack,
        to configuration: AVAssetDownloadConfiguration
    ) throws {
        try HLSAssetInterstitialConfiguration.apply(
            content,
            to: configuration
        )
    }

    /// Returns all tasks currently known to the background session.
    public func downloads() async -> [HLSAssetDownload] {
        let tasks = await allAssetDownloadTasks()
        return tasks.map(makeDownload)
    }

    #if !os(watchOS)
    /// Returns the latest system-managed asset location for a download.
    ///
    /// Persist the returned reference before the session's bounded terminal
    /// replay cache evicts the task.
    public func storedAsset(
        for download: HLSAssetDownload
    ) throws -> HLSStoredAsset? {
        guard download.sessionIdentifier == configuration.identifier else {
            throw HLSAssetDownloadSessionError.foreignSession
        }
        guard
            let location = eventHub.location(
                taskIdentifier: download.taskIdentifier
            )
        else {
            return nil
        }
        return try download.storedAsset(at: location)
    }
    #endif

    /// Observes progress, system location, and terminal state for one task.
    public func events(
        for download: HLSAssetDownload
    ) -> AsyncStream<HLSAssetDownloadEvent> {
        guard
            download.sessionIdentifier == configuration.identifier
        else {
            return AsyncStream { continuation in
                continuation.yield(
                    .failed(
                        Self.underlyingError(
                            .foreignSession
                        )
                    )
                )
                continuation.finish()
            }
        }
        return eventHub.stream(
            taskIdentifier: download.taskIdentifier
        )
    }

    /// Resumes a suspended task.
    public func resume(_ download: HLSAssetDownload) async throws {
        try await task(for: download).resume()
    }

    /// Suspends a running task without discarding system-managed state.
    public func suspend(_ download: HLSAssetDownload) async throws {
        try await task(for: download).suspend()
    }

    /// Cancels a task.
    public func cancel(_ download: HLSAssetDownload) async throws {
        try await task(for: download).cancel()
    }

    /// Wires the host application's background-session completion handler.
    public nonisolated func handleBackgroundSessionCompletion(
        _ identifier: String,
        completion: @escaping @Sendable () -> Void
    ) {
        guard identifier == configuration.identifier else {
            completion()
            return
        }
        guard !lifecycle.withLock({ $0.isInvalidating }) else {
            completion()
            return
        }
        backgroundCompletions.set(completion)
    }

    /// Invalidates the session after finishing or cancelling active tasks.
    @MainActor
    public func shutdown(
        cancelRunningTasks: Bool = false
    ) async {
        let shouldBegin = lifecycle.withLock { state in
            guard !state.isInvalidating else {
                return false
            }
            state.isInvalidating = true
            return true
        }
        if shouldBegin {
            if cancelRunningTasks {
                session.invalidateAndCancel()
            } else {
                session.finishTasksAndInvalidate()
            }
        }
        await invalidationGate.wait()
        sessionIdentifierLease.release()
    }

    deinit {
        session.invalidateAndCancel()
    }

    private func task(
        for download: HLSAssetDownload
    ) async throws -> AVAssetDownloadTask {
        guard download.sessionIdentifier == configuration.identifier else {
            throw HLSAssetDownloadSessionError.foreignSession
        }
        guard
            let task = await allAssetDownloadTasks().first(where: {
                $0.taskIdentifier == download.taskIdentifier
            })
        else {
            throw HLSAssetDownloadSessionError.downloadNotFound
        }
        return task
    }

    private func allAssetDownloadTasks() async
        -> [AVAssetDownloadTask]
    {
        let gate = HLSAssetDownloadTaskQueryGate()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.install(continuation)
                session.getAllTasks { tasks in
                    gate.complete(
                        tasks.compactMap {
                            $0 as? AVAssetDownloadTask
                        }
                    )
                }
            }
        } onCancel: {
            gate.complete([])
        }
    }

    private func makeDownload(
        _ task: AVAssetDownloadTask
    ) -> HLSAssetDownload {
        HLSAssetDownload(
            id:
                task.taskDescription
                ?? "\(configuration.identifier).\(task.taskIdentifier)",
            taskIdentifier: task.taskIdentifier,
            sessionIdentifier: configuration.identifier
        )
    }

    private static func validate(
        id: String,
        sourceURL: URL,
        title: String,
        artworkData: Data?
    ) throws {
        guard
            !id.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
        else {
            throw HLSAssetDownloadSessionError
                .invalidDownloadIdentifier
        }
        guard
            !title.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
        else {
            throw HLSAssetDownloadSessionError.invalidTitle
        }
        try HLSAssetDownloadAdmission.validateSourceURL(sourceURL)
        if let artworkData,
            artworkData.count > maximumArtworkBytes
        {
            throw HLSAssetDownloadSessionError.artworkTooLarge(
                limit: maximumArtworkBytes
            )
        }
    }

    private static func underlyingError(
        _ error: HLSAssetDownloadSessionError
    ) -> SendableUnderlyingError {
        SendableUnderlyingError(
            domain: "InnoNetworkHLSAVFoundation.Session",
            code: error.errorCode,
            message: String(describing: error)
        )
    }
}

private extension HLSAssetDownloadSessionError {
    var errorCode: Int {
        switch self {
        case .invalidSessionIdentifier:
            return 1
        case .duplicateSessionIdentifier:
            return 2
        case .invalidSharedContainerIdentifier:
            return 3
        case .invalidDownloadIdentifier:
            return 4
        case .invalidTitle:
            return 5
        case .insecureSourceURL:
            return 6
        case .invalidSourceURL:
            return 7
        case .artworkTooLarge:
            return 8
        case .taskCreationFailed:
            return 9
        case .downloadNotFound:
            return 10
        case .sessionInvalidating:
            return 11
        case .foreignSession:
            return 12
        case .interstitialAssetsUnavailable:
            return 13
        }
    }
}

private enum HLSAssetDownloadSessionIdentifierRegistry {
    private static let activeIdentifiers =
        OSAllocatedUnfairLock(initialState: Set<String>())

    static func acquire(_ identifier: String) -> Bool {
        activeIdentifiers.withLock {
            $0.insert(identifier).inserted
        }
    }

    static func release(_ identifier: String) {
        _ = activeIdentifiers.withLock {
            $0.remove(identifier)
        }
    }
}

private final class HLSAssetDownloadSessionIdentifierLease: Sendable {
    let identifier: String
    private let didRelease = OSAllocatedUnfairLock(
        initialState: false
    )

    init(identifier: String) {
        self.identifier = identifier
    }

    func release() {
        let shouldRelease = didRelease.withLock { didRelease in
            guard !didRelease else {
                return false
            }
            didRelease = true
            return true
        }
        if shouldRelease {
            HLSAssetDownloadSessionIdentifierRegistry.release(
                identifier
            )
        }
    }
}

@available(macOS 12.0, iOS 15.0, watchOS 10.0, visionOS 1.0, *)
private final class HLSAssetDownloadTaskQueryGate: Sendable {
    private struct State {
        var continuation: CheckedContinuation<[AVAssetDownloadTask], Never>?
        var result: [AVAssetDownloadTask]?
        var isComplete = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func install(
        _ continuation:
            CheckedContinuation<[AVAssetDownloadTask], Never>
    ) {
        let result: [AVAssetDownloadTask]? = state.withLock { state in
            guard state.isComplete else {
                state.continuation = continuation
                return nil
            }
            return state.result ?? []
        }
        if let result {
            continuation.resume(returning: result)
        }
    }

    func complete(_ result: [AVAssetDownloadTask]) {
        let continuation: CheckedContinuation<[AVAssetDownloadTask], Never>? =
            state.withLock { state in
                guard !state.isComplete else {
                    return nil
                }
                state.isComplete = true
                state.result = result
                let continuation = state.continuation
                state.continuation = nil
                return continuation
            }
        continuation?.resume(returning: result)
    }
}
#endif
