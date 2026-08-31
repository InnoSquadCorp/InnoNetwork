import Foundation
import InnoNetwork
import Testing

@testable import InnoNetworkHLSLive

@Suite("HLS live DVR preload runtime", .serialized)
struct HLSLiveDVRPreloadRuntimeTests {
    @Test(
        "confirmed PART and MAP hints are reused over loopback HTTP",
        .timeLimit(.minutes(1))
    )
    func reusesConfirmedHints() async throws {
        guard
            let rawURL = ProcessInfo.processInfo.environment[
                "INNONETWORK_HLS_LIVE_PRELOAD_RUNTIME_URL"
            ],
            let playlistURL = URL(string: rawURL)
        else {
            try Test.cancel()
        }

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
        #expect(
            try Data(
                contentsOf: destinationURL.appendingPathComponent(
                    "resources/initialization.mp4"
                )
            ) == Data("runtime-init".utf8)
        )
    }
}
