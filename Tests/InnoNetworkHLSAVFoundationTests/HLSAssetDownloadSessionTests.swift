#if canImport(AVFoundation) && !os(tvOS)
import AVFoundation
import Foundation
import Testing
import os

@testable import InnoNetworkHLSAVFoundation

@Suite("AVFoundation HLS session", .serialized)
struct HLSAssetDownloadSessionTests {
    @Test("session identifiers are validated and exclusively owned")
    func sessionIdentifierAdmission() async throws {
        #expect(throws: HLSAssetDownloadSessionError.invalidSessionIdentifier) {
            try HLSAssetDownloadSession(
                configuration: HLSAssetDownloadSessionPack(
                    identifier: " "
                )
            )
        }

        let identifier = "com.innonetwork.tests.\(UUID().uuidString)"
        let session = try HLSAssetDownloadSession(
            configuration: HLSAssetDownloadSessionPack(
                identifier: identifier
            )
        )
        #expect(throws: HLSAssetDownloadSessionError.duplicateSessionIdentifier) {
            try HLSAssetDownloadSession(
                configuration: HLSAssetDownloadSessionPack(
                    identifier: identifier
                )
            )
        }
        await session.shutdown(cancelRunningTasks: true)

        let replacement = try HLSAssetDownloadSession(
            configuration: HLSAssetDownloadSessionPack(
                identifier: identifier
            )
        )
        await replacement.shutdown(cancelRunningTasks: true)
    }

    @MainActor
    @Test("shutdown prevents later task creation")
    func shutdownRejectsNewTasks() async throws {
        let session = try HLSAssetDownloadSession(
            configuration: HLSAssetDownloadSessionPack(
                identifier:
                    "com.innonetwork.tests.\(UUID().uuidString)"
            )
        )
        await session.shutdown(cancelRunningTasks: true)

        #expect(throws: HLSAssetDownloadSessionError.sessionInvalidating) {
            try session.start(
                HLSAssetDownloadRequest(
                    sourceURL: try #require(
                        URL(string: "https://media.example/asset.m3u8")
                    ),
                    title: "Example"
                )
            )
        }
    }

    @MainActor
    @Test("start validates inputs and configures the system task")
    func startValidationAndConfiguration() async throws {
        let session = try HLSAssetDownloadSession(
            configuration: HLSAssetDownloadSessionPack(
                identifier:
                    "com.innonetwork.tests.\(UUID().uuidString)"
            )
        )

        #expect(throws: HLSAssetDownloadSessionError.insecureSourceURL) {
            try session.start(
                HLSAssetDownloadRequest(
                    sourceURL: try #require(
                        URL(string: "http://media.example/asset.m3u8")
                    ),
                    title: "Example"
                )
            )
        }
        #expect(throws: HLSAssetDownloadSessionError.invalidTitle) {
            try session.start(
                HLSAssetDownloadRequest(
                    sourceURL: try #require(
                        URL(string: "https://media.example/asset.m3u8")
                    ),
                    title: " "
                )
            )
        }
        #expect(throws: HLSAssetDownloadSessionError.invalidSourceURL) {
            try session.start(
                HLSAssetDownloadRequest(
                    sourceURL: try #require(
                        URL(
                            string:
                                "https://user:password@media.example/asset.m3u8"
                        )
                    ),
                    title: "Example"
                )
            )
        }

        let configured = OSAllocatedUnfairLock(initialState: false)
        let download = try session.start(
            HLSAssetDownloadRequest(
                id: "episode-1",
                sourceURL: try #require(
                    URL(string: "https://media.example/asset.m3u8")
                ),
                title: "Episode 1"
            ),
            startsImmediately: false
        ) { configuration in
            configuration.auxiliaryContentConfigurations = []
            configured.withLock { $0 = true }
        }

        #expect(download.id == "episode-1")
        #expect(configured.withLock { $0 })
        #expect(await session.downloads().contains(download))
        try await session.cancel(download)
        await session.shutdown(cancelRunningTasks: true)
    }

    @MainActor
    @Test("typed content selection enables interstitial downloads")
    func interstitialContentSelection() async throws {
        let pack = HLSAssetDownloadContentPack(
            includesInterstitialAssets: true
        )
        #expect(pack.includesInterstitialAssets)

        let session = try HLSAssetDownloadSession(
            configuration: HLSAssetDownloadSessionPack(
                identifier:
                    "com.innonetwork.tests.\(UUID().uuidString)"
            )
        )
        let request = HLSAssetDownloadRequest(
            id: "interstitial",
            sourceURL: try #require(
                URL(string: "https://media.example/asset.m3u8")
            ),
            title: "Interstitial"
        )

        #if compiler(<6.4)
        #expect(
            throws:
                HLSAssetDownloadSessionError
                .interstitialAssetsUnavailable
        ) {
            try session.start(
                request,
                content: pack,
                startsImmediately: false
            ) { _ in }
        }
        #else
        if #available(macOS 15, iOS 18, watchOS 11, visionOS 2, *) {
            let observed = OSAllocatedUnfairLock(initialState: false)
            let download = try session.start(
                request,
                content: pack,
                startsImmediately: false
            ) { configuration in
                let includesInterstitialAssets =
                    configuration.downloadsInterstitialAssets
                observed.withLock {
                    $0 = includesInterstitialAssets
                }
            }
            #expect(observed.withLock { $0 })
            try await session.cancel(download)
        } else {
            #expect(
                throws:
                    HLSAssetDownloadSessionError
                    .interstitialAssetsUnavailable
            ) {
                try session.start(
                    request,
                    content: pack,
                    startsImmediately: false
                ) { _ in }
            }
        }
        #endif
        await session.shutdown(cancelRunningTasks: true)
    }

    @Test("a foreign background completion is released immediately")
    func foreignBackgroundCompletion() async throws {
        let session = try HLSAssetDownloadSession(
            configuration: HLSAssetDownloadSessionPack(
                identifier:
                    "com.innonetwork.tests.\(UUID().uuidString)"
            )
        )
        let didComplete = OSAllocatedUnfairLock(initialState: false)

        session.handleBackgroundSessionCompletion(
            "com.example.other"
        ) {
            didComplete.withLock { $0 = true }
        }

        #expect(didComplete.withLock { $0 })
        await session.shutdown(cancelRunningTasks: true)
    }

    @Test("system and application cancellation are classified")
    func cancellationClassification() {
        #expect(
            HLSAssetDownloadDelegate.isCancellation(
                URLError(.cancelled)
            )
        )
        #expect(
            HLSAssetDownloadDelegate.isCancellation(
                CocoaError(.userCancelled)
            )
        )
        #expect(
            !HLSAssetDownloadDelegate.isCancellation(
                URLError(.timedOut)
            )
        )
    }

    @Test("session failures expose actionable localized diagnostics")
    func sessionErrorDiagnostics() {
        let configurationError =
            HLSAssetDownloadSessionError.invalidSessionIdentifier
        #expect(!configurationError.localizedDescription.isEmpty)
        #expect(configurationError.recoverySuggestion?.isEmpty == false)
        #expect(!configurationError.isRetriableHint)

        let transientError =
            HLSAssetDownloadSessionError.taskCreationFailed
        #expect(transientError.isRetriableHint)
        #expect(transientError.recoverySuggestion?.isEmpty == false)
    }
}
#endif
