import Foundation
import InnoNetworkHLS
import Testing

@testable import InnoNetworkHLSLive

extension HLSLivePlaylistClientTests {
    @Test("concurrent finite streams remain isolated")
    func concurrentEndedStreams() async throws {
        let session = makeRaceSession()
        defer {
            session.invalidateAndCancel()
            HLSLiveURLProtocol.reset()
        }
        let streamCount = 64
        for index in 0..<streamCount {
            let sourceURL = try #require(
                URL(
                    string:
                        "https://media.example/concurrent-\(index).m3u8"
                )
            )
            HLSLiveURLProtocol.register(
                raceResponse(sequenceNumber: Int64(index)),
                for: sourceURL
            )
        }
        let client = HLSLivePlaylistClient(session: session)

        let snapshots = try await withThrowingTaskGroup(
            of: HLSLivePlaylistSnapshot.self,
            returning: [HLSLivePlaylistSnapshot].self
        ) { group in
            for index in 0..<streamCount {
                group.addTask {
                    let sourceURL = try #require(
                        URL(
                            string:
                                "https://media.example/concurrent-\(index).m3u8"
                        )
                    )
                    var iterator = client.snapshots(
                        from: sourceURL
                    ).makeAsyncIterator()
                    let snapshot = try #require(
                        try await iterator.next()
                    )
                    #expect(try await iterator.next() == nil)
                    return snapshot
                }
            }
            var snapshots: [HLSLivePlaylistSnapshot] = []
            for try await snapshot in group {
                snapshots.append(snapshot)
            }
            return snapshots
        }

        #expect(snapshots.count == streamCount)
        #expect(snapshots.allSatisfy { $0.isEnded })
        #expect(
            Set(
                snapshots.compactMap {
                    $0.segments.first?.sequenceNumber
                }
            ) == Set((0..<streamCount).map(Int64.init))
        )
        #expect(
            HLSLiveURLProtocol.capturedRequests().count
                == streamCount
        )
    }

    private func makeRaceSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HLSLiveURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func raceResponse(
        sequenceNumber: Int64
    ) -> HLSLiveURLProtocol.Response {
        HLSLiveURLProtocol.Response(
            statusCode: 200,
            data: Data(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:\(sequenceNumber)
                #EXTINF:4,
                segment.ts
                #EXT-X-ENDLIST
                """.utf8
            ),
            headers: [
                "Content-Type":
                    "application/vnd.apple.mpegurl"
            ]
        )
    }
}
