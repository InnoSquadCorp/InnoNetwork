import Foundation
import InnoNetwork
import Testing

@testable import InnoNetworkHLSLive

@Suite("HLS live DVR preload runtime", .serialized)
struct HLSLiveDVRPreloadRuntimeTests {
    @Test(
        "confirmed PART and MAP hints are reused over loopback HTTP",
        .hlsRuntimeURL("INNONETWORK_HLS_LIVE_PRELOAD_RUNTIME_URL"),
        .timeLimit(.minutes(1))
    )
    func reusesConfirmedHints() async throws {
        let playlistURL = try hlsRuntimeURL(
            environmentKey: "INNONETWORK_HLS_LIVE_PRELOAD_RUNTIME_URL"
        )

        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "innonetwork-live-preload-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(at: destinationURL)
        }
        let configuration = HLSLiveDVRConfiguration.advanced(
            parts: HLSLiveDVRPartPack(policy: .independent),
            preloading: HLSLiveDVRPreloadPack(
                policy: .unencryptedMedia,
                maximumTotalBytes: 32 * 1_024 * 1_024
            )
        )
        let requestContext = NetworkRequestContext(
            requestID: UUID(),
            retryIndex: 0,
            metricsReporter: nil,
            trustPolicy: .systemDefault,
            eventObservers: [],
            redirectPolicy: DefaultRedirectPolicy(),
            allowsInsecureHTTP: true,
            allowsAutomaticRedirects: true,
            allowsURLCacheStorage: true
        )
        let client = HLSLivePlaylistClient(
            session: .shared,
            requestContext: requestContext
        )

        let receipt = try await HLSLiveDVRRecorder(
            client: client,
            configuration: configuration
        ).record(from: playlistURL, to: destinationURL)

        #expect(receipt.segmentCount == 1)
        #expect(receipt.promotedPartCount == 2)
        let partStatistics =
            receipt.preloadStatistics.partialSegments
        #expect(partStatistics.requestCount == 2)
        #expect(partStatistics.completedCount == 2)
        #expect(partStatistics.confirmedCount == 2)
        #expect(partStatistics.reuseCount == 2)
        #expect(partStatistics.missCount == 0)
        #expect(partStatistics.transferredByteCount == 22)
        #expect(partStatistics.reusedByteCount == 22)
        let mapStatistics =
            receipt.preloadStatistics.initializationMaps
        #expect(mapStatistics.requestCount == 1)
        #expect(mapStatistics.completedCount == 1)
        #expect(mapStatistics.confirmedCount == 1)
        #expect(mapStatistics.reuseCount == 1)
        #expect(mapStatistics.missCount == 0)
        #expect(mapStatistics.transferredByteCount == 12)
        #expect(mapStatistics.reusedByteCount == 12)
        #expect(
            try Data(
                contentsOf: destinationURL.appendingPathComponent(
                    "resources/initialization.mp4"
                )
            ) == Data("runtime-init".utf8)
        )
    }
}
