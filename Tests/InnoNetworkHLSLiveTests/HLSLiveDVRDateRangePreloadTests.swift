import Foundation
import InnoNetworkHLS
import Testing

@testable import InnoNetworkHLSLive

extension HLSLivePlaylistClientTests {
    @Test("outstanding preload attempts are bounded and deduplicated")
    func boundsDateRangePreloads() async throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/live.m3u8")
        )
        let declarations = (0..<33).map { index in
            let second = String(format: "%02d", index)
            return
                "#EXT-X-DATERANGE:ID=\"preload-\(index)\",CLASS=\"com.apple.hls.preload\",START-DATE=\"2026-09-01T00:00:\(second)Z\",DURATION=1,X-URI=\"https://schedule.example/\(index).json\",X-TARGET-ID=\"schedule-\(index)\",X-TARGET-CLASS=\"com.apple.hls.daterange-schedule\""
        }.joined(separator: "\n")
        let playlist = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-PROGRAM-DATE-TIME:2026-09-01T00:00:00Z
            #EXTINF:60,
            current.ts
            \(declarations)
            """,
            relativeTo: sourceURL
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HLSLiveURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            HLSLiveURLProtocol.reset()
        }
        for index in 0..<33 {
            let url = try #require(
                URL(string: "https://schedule.example/\(index).json")
            )
            HLSLiveURLProtocol.register(
                .init(
                    statusCode: 200,
                    data: Data("{}".utf8),
                    headers: [:]
                ),
                for: url
            )
        }
        let coordinator = HLSLiveDVRDateRangePreloadCoordinator(
            resolver: HLSExternalResourceResolver(session: session)
        )
        let snapshot = HLSLivePlaylistSnapshot(
            playlist: playlist,
            segments: [],
            partialSegments: [],
            dateRanges: playlist.dateRanges,
            generation: 0,
            isDeltaUpdate: false,
            isEnded: false
        )

        await coordinator.update(
            from: snapshot,
            excludingTargetIDs: []
        )
        for _ in 0..<100 {
            if HLSLiveURLProtocol.capturedRequests().count == 32 {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        await coordinator.update(
            from: snapshot,
            excludingTargetIDs: []
        )
        try await Task.sleep(for: .milliseconds(10))

        let requests = HLSLiveURLProtocol.capturedRequests()
            .compactMap(\.url)
        await coordinator.cancelAll()
        #expect(requests.count == 32)
        #expect(Set(requests).count == 32)
        #expect(
            !requests.contains(
                try #require(
                    URL(string: "https://schedule.example/32.json")
                )
            )
        )
    }
}
