#if canImport(AVFoundation) && (os(macOS) || os(iOS))
import AVFoundation
import Foundation
import Testing
import os

@testable import InnoNetworkHLSAVFoundation

@Suite("Offline HLS asset runtime", .serialized)
struct HLSOfflineAssetRuntimeTests {
    @Test(
        "a downloaded movpkg reports a complete offline rendition",
        .timeLimit(.minutes(1))
    )
    func downloadedPackageIsReady() async throws {
        guard
            let rawURL = ProcessInfo.processInfo.environment[
                "INNONETWORK_HLS_RUNTIME_PLAYLIST_URL"
            ],
            let playlistURL = URL(string: rawURL)
        else {
            try Test.cancel()
        }

        let delegate = HLSOfflineAssetDownloadProbe()
        let configuration = URLSessionConfiguration.background(
            withIdentifier:
                "com.innonetwork.tests.offline.\(UUID().uuidString)"
        )
        configuration.sessionSendsLaunchEvents = false
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = AVAssetDownloadURLSession(
            configuration: configuration,
            assetDownloadDelegate: delegate,
            delegateQueue: queue
        )
        defer {
            session.invalidateAndCancel()
        }
        let task = try #require(
            session.makeAssetDownloadTask(
                asset: AVURLAsset(url: playlistURL),
                assetTitle: "InnoNetwork runtime fixture",
                assetArtworkData: nil,
                options: nil
            )
        )
        task.resume()

        let location = try await delegate.result()
        session.finishTasksAndInvalidate()
        defer {
            try? FileManager.default.removeItem(at: location)
        }
        let storedAsset = try HLSStoredAsset(
            id: "runtime-offline-asset",
            location: location
        )
        let snapshot = try await HLSOfflineAssetInspector().inspect(
            storedAsset
        )

        #expect(snapshot.state == .ready)
        #expect(snapshot.isPlayableOffline)
        #expect(snapshot.didCompleteMediaSelectionInspection)
    }
}

private final class HLSOfflineAssetDownloadProbe:
    NSObject,
    AVAssetDownloadDelegate
{
    private let continuation = AsyncThrowingStream<URL, any Error>
        .makeStream(bufferingPolicy: .bufferingNewest(1))
    private let location = OSAllocatedUnfairLock<URL?>(
        initialState: nil
    )

    func result() async throws -> URL {
        var iterator = continuation.stream.makeAsyncIterator()
        return try #require(try await iterator.next())
    }

    func urlSession(
        _ session: URLSession,
        assetDownloadTask: AVAssetDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        self.location.withLock { $0 = location }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        if let error {
            continuation.continuation.finish(throwing: error)
            return
        }
        guard let location = location.withLock({ $0 }) else {
            continuation.continuation.finish(
                throwing: URLError(.cannotCreateFile)
            )
            return
        }
        continuation.continuation.yield(location)
        continuation.continuation.finish()
    }
}
#endif
