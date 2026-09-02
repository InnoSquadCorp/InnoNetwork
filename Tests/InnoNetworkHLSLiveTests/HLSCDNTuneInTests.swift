import Foundation
import InnoNetworkHLS
import Testing

@testable import InnoNetworkHLSLive

extension HLSLivePlaylistClientTests {
    @Test("initial tune-in removes prior reload directives")
    func removesPriorReloadDirectivesFromInitialRequest() async throws {
        let sourceURL = try #require(
            URL(
                string:
                    "https://media.example/cdn-clean.m3u8?token=secret&_HLS_msn=7&_HLS_part=2&_HLS_skip=YES"
            )
        )
        let cleanURL = try #require(
            URL(
                string:
                    "https://media.example/cdn-clean.m3u8?token=secret"
            )
        )
        let session = makeCDNTuneInSession()
        defer {
            session.invalidateAndCancel()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            HLSLiveURLProtocol.Response(
                statusCode: 200,
                data: Data(
                    """
                    #EXTM3U
                    #EXT-X-TARGETDURATION:4
                    #EXT-X-MEDIA-SEQUENCE:1
                    #EXTINF:4,
                    1.ts
                    #EXT-X-ENDLIST
                    """.utf8
                ),
                headers: [
                    "Content-Type": "application/vnd.apple.mpegurl"
                ]
            ),
            for: cleanURL
        )

        let snapshot = try await HLSLivePlaylistClient(
            resolver: PlaylistResolver(session: session),
            configuration: .safeDefaults()
        ).snapshot(from: sourceURL)

        #expect(snapshot.isEnded)
        #expect(
            HLSLiveURLProtocol.capturedRequests().compactMap(\.url)
                == [cleanURL]
        )
    }

    @Test("stale LL-HLS CDN responses tune in near the live edge")
    func tunesInFromStaleCDNResponse() async throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/cdn-live.m3u8")
        )
        let tuneInURL = try #require(
            URL(
                string:
                    "https://media.example/cdn-live.m3u8?_HLS_msn=103&_HLS_part=3"
            )
        )
        let session = makeCDNTuneInSession()
        defer {
            session.invalidateAndCancel()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            cdnTuneInResponse(
                """
                #EXTM3U
                #EXT-X-VERSION:9
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:100
                #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=3
                #EXT-X-PART-INF:PART-TARGET=1
                #EXTINF:4,
                100.ts
                #EXTINF:4,
                101.ts
                #EXT-X-PRELOAD-HINT:TYPE=PART,URI="102.0.ts"
                """,
                age: 8
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            cdnTuneInResponse(
                """
                #EXTM3U
                #EXT-X-VERSION:9
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:102
                #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=3
                #EXT-X-PART-INF:PART-TARGET=1
                #EXTINF:4,
                102.ts
                #EXTINF:4,
                103.ts
                #EXT-X-PRELOAD-HINT:TYPE=PART,URI="104.0.ts"
                """,
                age: 0
            ),
            for: tuneInURL
        )

        let measuredAt = Date(timeIntervalSince1970: 1_000)
        let snapshot = try await HLSLivePlaylistClient(
            resolver: PlaylistResolver(session: session),
            configuration: .safeDefaults(),
            now: { measuredAt }
        ).snapshot(from: sourceURL)

        #expect(snapshot.reloadMode == .cdnTuneIn)
        #expect(
            snapshot.segments.map(\.sequenceNumber)
                == [102, 103]
        )
        #expect(snapshot.httpFreshness?.reportedAge == 0)
        #expect(
            HLSLiveURLProtocol.capturedRequests().compactMap(\.url)
                == [sourceURL, tuneInURL]
        )
    }

    @Test("subsecond PART targets add the specified tune-in margin")
    func addsSubsecondTuneInMargin() async throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/subsecond.m3u8")
        )
        let tuneInURL = try #require(
            URL(
                string:
                    "https://media.example/subsecond.m3u8?_HLS_msn=11&_HLS_part=1"
            )
        )
        let session = makeCDNTuneInSession()
        defer {
            session.invalidateAndCancel()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            cdnTuneInResponse(
                """
                #EXTM3U
                #EXT-X-VERSION:9
                #EXT-X-TARGETDURATION:2
                #EXT-X-MEDIA-SEQUENCE:10
                #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=1
                #EXT-X-PART-INF:PART-TARGET=0.5
                #EXTINF:2,
                10.ts
                #EXT-X-PRELOAD-HINT:TYPE=PART,URI="11.0.ts"
                """,
                age: 0
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            cdnTuneInResponse(
                """
                #EXTM3U
                #EXT-X-VERSION:9
                #EXT-X-TARGETDURATION:2
                #EXT-X-MEDIA-SEQUENCE:11
                #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=1
                #EXT-X-PART-INF:PART-TARGET=0.5
                #EXT-X-PART:DURATION=0.5,URI="11.0.ts",INDEPENDENT=YES
                #EXT-X-PART:DURATION=0.5,URI="11.1.ts"
                #EXT-X-PRELOAD-HINT:TYPE=PART,URI="11.2.ts"
                """,
                age: 0
            ),
            for: tuneInURL
        )

        let measuredAt = Date(timeIntervalSince1970: 1_000)
        let snapshot = try await HLSLivePlaylistClient(
            resolver: PlaylistResolver(session: session),
            configuration: .safeDefaults(),
            now: { measuredAt }
        ).snapshot(from: sourceURL)

        #expect(snapshot.reloadMode == .cdnTuneIn)
        #expect(snapshot.partialSegments.map(\.partIndex) == [0, 1])
        #expect(
            HLSLiveURLProtocol.capturedRequests().compactMap(\.url)
                == [sourceURL, tuneInURL]
        )
    }

    @Test("CDN tune-in requests stay bounded")
    func boundsCDNTuneInRequests() async throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/bounded-cdn.m3u8")
        )
        let tuneInURL = try #require(
            URL(
                string:
                    "https://media.example/bounded-cdn.m3u8?_HLS_msn=23&_HLS_part=3"
            )
        )
        let session = makeCDNTuneInSession()
        defer {
            session.invalidateAndCancel()
            HLSLiveURLProtocol.reset()
        }
        let staleResponse = cdnTuneInResponse(
            """
            #EXTM3U
            #EXT-X-VERSION:9
            #EXT-X-TARGETDURATION:4
            #EXT-X-MEDIA-SEQUENCE:20
            #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=3
            #EXT-X-PART-INF:PART-TARGET=1
            #EXTINF:4,
            20.ts
            #EXTINF:4,
            21.ts
            #EXT-X-PRELOAD-HINT:TYPE=PART,URI="22.0.ts"
            """,
            age: 8
        )
        HLSLiveURLProtocol.register(staleResponse, for: sourceURL)
        HLSLiveURLProtocol.register(staleResponse, for: tuneInURL)
        HLSLiveURLProtocol.register(staleResponse, for: tuneInURL)

        let measuredAt = Date(timeIntervalSince1970: 1_000)
        let snapshot = try await HLSLivePlaylistClient(
            resolver: PlaylistResolver(session: session),
            configuration: .advanced(
                cdnTuneIn: HLSLiveCDNTuneInPack(
                    maximumAdditionalRequestCount: 2
                )
            ),
            now: { measuredAt }
        ).snapshot(from: sourceURL)

        #expect(snapshot.reloadMode == .cdnTuneIn)
        #expect(HLSLiveURLProtocol.capturedRequests().count == 3)
        #expect(
            HLSLiveURLProtocol.capturedRequests().dropFirst()
                .allSatisfy { $0.url == tuneInURL }
        )
    }

    @Test("unmergeable CDN tune-in responses preserve the first snapshot")
    func preservesInitialSnapshotAfterInvalidTuneIn() async throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/cdn-fallback.m3u8")
        )
        let tuneInURL = try #require(
            URL(
                string:
                    "https://media.example/cdn-fallback.m3u8?_HLS_msn=103&_HLS_part=3"
            )
        )
        let session = makeCDNTuneInSession()
        defer {
            session.invalidateAndCancel()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            cdnTuneInResponse(
                """
                #EXTM3U
                #EXT-X-VERSION:9
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:100
                #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,CAN-SKIP-UNTIL=24,PART-HOLD-BACK=3
                #EXT-X-PART-INF:PART-TARGET=1
                #EXTINF:4,
                100.ts
                #EXTINF:4,
                101.ts
                #EXT-X-PRELOAD-HINT:TYPE=PART,URI="102.0.ts"
                """,
                age: 8
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            cdnTuneInResponse(
                """
                #EXTM3U
                #EXT-X-VERSION:9
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:100
                #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,CAN-SKIP-UNTIL=24,PART-HOLD-BACK=3
                #EXT-X-PART-INF:PART-TARGET=1
                #EXT-X-SKIP:SKIPPED-SEGMENTS=1
                #EXTINF:4,
                101.ts
                #EXT-X-PRELOAD-HINT:TYPE=PART,URI="102.0.ts"
                """,
                age: 8
            ),
            for: tuneInURL
        )

        let measuredAt = Date(timeIntervalSince1970: 1_000)
        let snapshot = try await HLSLivePlaylistClient(
            resolver: PlaylistResolver(session: session),
            configuration: .safeDefaults(),
            now: { measuredAt }
        ).snapshot(from: sourceURL)

        #expect(snapshot.reloadMode == .initial)
        #expect(
            snapshot.segments.map(\.sequenceNumber)
                == [100, 101]
        )
        #expect(
            HLSLiveURLProtocol.capturedRequests().compactMap(\.url)
                == [sourceURL, tuneInURL]
        )
    }

    @Test("a later failed tune-in retains the newest valid snapshot")
    func preservesLatestSnapshotAfterFailedTuneIn() async throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/cdn-latest-fallback.m3u8")
        )
        let tuneInURL = try #require(
            URL(
                string:
                    "https://media.example/cdn-latest-fallback.m3u8?_HLS_msn=103&_HLS_part=3"
            )
        )
        let session = makeCDNTuneInSession()
        defer {
            session.invalidateAndCancel()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            cdnTuneInResponse(
                """
                #EXTM3U
                #EXT-X-VERSION:9
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:100
                #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=3
                #EXT-X-PART-INF:PART-TARGET=1
                #EXTINF:4,
                100.ts
                #EXTINF:4,
                101.ts
                #EXT-X-PRELOAD-HINT:TYPE=PART,URI="102.0.ts"
                """,
                age: 8
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            cdnTuneInResponse(
                """
                #EXTM3U
                #EXT-X-VERSION:9
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:102
                #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=3
                #EXT-X-PART-INF:PART-TARGET=1
                #EXTINF:4,
                102.ts
                #EXT-X-PRELOAD-HINT:TYPE=PART,URI="103.0.ts"
                """,
                age: 8
            ),
            for: tuneInURL
        )
        HLSLiveURLProtocol.register(
            cdnTuneInResponse("not a playlist", age: 8),
            for: tuneInURL
        )

        let measuredAt = Date(timeIntervalSince1970: 1_000)
        let snapshot = try await HLSLivePlaylistClient(
            resolver: PlaylistResolver(session: session),
            configuration: .safeDefaults(),
            now: { measuredAt }
        ).snapshot(from: sourceURL)

        #expect(snapshot.reloadMode == .cdnTuneIn)
        #expect(snapshot.segments.map(\.sequenceNumber) == [102])
        #expect(
            HLSLiveURLProtocol.capturedRequests().compactMap(\.url)
                == [sourceURL, tuneInURL, tuneInURL]
        )
    }

    @Test("tune-in completion uses actual media duration")
    func usesActualMediaAdvancement() async throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/cdn-duration.m3u8")
        )
        let firstTuneInURL = try #require(
            URL(
                string:
                    "https://media.example/cdn-duration.m3u8?_HLS_msn=11&_HLS_part=3"
            )
        )
        let secondTuneInURL = try #require(
            URL(
                string:
                    "https://media.example/cdn-duration.m3u8?_HLS_msn=12&_HLS_part=1"
            )
        )
        let session = makeCDNTuneInSession()
        defer {
            session.invalidateAndCancel()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            cdnTuneInResponse(
                """
                #EXTM3U
                #EXT-X-VERSION:9
                #EXT-X-TARGETDURATION:6
                #EXT-X-MEDIA-SEQUENCE:10
                #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=2
                #EXT-X-PART-INF:PART-TARGET=1
                #EXTINF:2,
                10.ts
                #EXT-X-PRELOAD-HINT:TYPE=PART,URI="11.0.ts"
                """,
                age: 4
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            cdnTuneInResponse(
                """
                #EXTM3U
                #EXT-X-VERSION:9
                #EXT-X-TARGETDURATION:6
                #EXT-X-MEDIA-SEQUENCE:11
                #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=2
                #EXT-X-PART-INF:PART-TARGET=1
                #EXTINF:2,
                11.ts
                #EXT-X-PART:DURATION=1,URI="12.0.ts",INDEPENDENT=YES
                #EXT-X-PRELOAD-HINT:TYPE=PART,URI="12.1.ts"
                """,
                age: 4
            ),
            for: firstTuneInURL
        )
        HLSLiveURLProtocol.register(
            cdnTuneInResponse(
                """
                #EXTM3U
                #EXT-X-VERSION:9
                #EXT-X-TARGETDURATION:6
                #EXT-X-MEDIA-SEQUENCE:11
                #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=2
                #EXT-X-PART-INF:PART-TARGET=1
                #EXTINF:2,
                11.ts
                #EXT-X-PART:DURATION=1,URI="12.0.ts",INDEPENDENT=YES
                #EXT-X-PART:DURATION=1,URI="12.1.ts"
                #EXT-X-PRELOAD-HINT:TYPE=PART,URI="12.2.ts"
                """,
                age: 0
            ),
            for: secondTuneInURL
        )

        let measuredAt = Date(timeIntervalSince1970: 1_000)
        let snapshot = try await HLSLivePlaylistClient(
            resolver: PlaylistResolver(session: session),
            configuration: .safeDefaults(),
            now: { measuredAt }
        ).snapshot(from: sourceURL)

        #expect(snapshot.segments.map(\.sequenceNumber) == [11])
        #expect(snapshot.partialSegments.map(\.partIndex) == [0, 1])
        #expect(
            HLSLiveURLProtocol.capturedRequests().compactMap(\.url)
                == [sourceURL, firstTuneInURL, secondTuneInURL]
        )
    }

    @Test("completed parts do not move CDN tune-in behind the live edge")
    func tunesInAfterCompletedParts() async throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/cdn-completed-parts.m3u8")
        )
        let tuneInURL = try #require(
            URL(
                string:
                    "https://media.example/cdn-completed-parts.m3u8?_HLS_msn=12&_HLS_part=3"
            )
        )
        let session = makeCDNTuneInSession()
        defer {
            session.invalidateAndCancel()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            cdnTuneInResponse(
                """
                #EXTM3U
                #EXT-X-VERSION:9
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:10
                #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=3
                #EXT-X-PART-INF:PART-TARGET=1
                #EXT-X-PART:DURATION=1,URI="10.0.ts",INDEPENDENT=YES
                #EXT-X-PART:DURATION=1,URI="10.1.ts"
                #EXT-X-PART:DURATION=1,URI="10.2.ts"
                #EXT-X-PART:DURATION=1,URI="10.3.ts"
                #EXTINF:4,
                10.ts
                #EXTINF:4,
                11.ts
                #EXT-X-PRELOAD-HINT:TYPE=PART,URI="12.0.ts"
                """,
                age: 4
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            cdnTuneInResponse(
                """
                #EXTM3U
                #EXT-X-VERSION:9
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:12
                #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=3
                #EXT-X-PART-INF:PART-TARGET=1
                #EXTINF:4,
                12.ts
                #EXT-X-ENDLIST
                """,
                age: 0
            ),
            for: tuneInURL
        )

        let measuredAt = Date(timeIntervalSince1970: 1_000)
        let snapshot = try await HLSLivePlaylistClient(
            resolver: PlaylistResolver(session: session),
            configuration: .safeDefaults(),
            now: { measuredAt }
        ).snapshot(from: sourceURL)

        #expect(snapshot.reloadMode == .cdnTuneIn)
        #expect(snapshot.segments.map(\.sequenceNumber) == [12])
        #expect(
            HLSLiveURLProtocol.capturedRequests().compactMap(\.url)
                == [sourceURL, tuneInURL]
        )
    }

    @Test("CDN tune-in settings clamp and can be disabled")
    func configuresCDNTuneIn() {
        let maximum = HLSLiveCDNTuneInPack(
            maximumAdditionalRequestCount: .max
        ).resolvedSettings()
        let minimum = HLSLiveCDNTuneInPack(
            isEnabled: false,
            maximumAdditionalRequestCount: .min
        ).resolvedSettings()

        #expect(maximum.isEnabled)
        #expect(maximum.maximumAdditionalRequestCount == 8)
        #expect(!minimum.isEnabled)
        #expect(minimum.maximumAdditionalRequestCount == 1)
    }

    @Test("snapshot streams publish only the tuned initial response")
    func streamsTunedInitialResponse() async throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/cdn-stream.m3u8")
        )
        let tuneInURL = try #require(
            URL(
                string:
                    "https://media.example/cdn-stream.m3u8?_HLS_msn=2&_HLS_part=3"
            )
        )
        let session = makeCDNTuneInSession()
        defer {
            session.invalidateAndCancel()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            cdnTuneInResponse(
                """
                #EXTM3U
                #EXT-X-VERSION:9
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:1
                #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=3
                #EXT-X-PART-INF:PART-TARGET=1
                #EXTINF:4,
                1.ts
                #EXT-X-PRELOAD-HINT:TYPE=PART,URI="2.0.ts"
                """,
                age: 4
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            cdnTuneInResponse(
                """
                #EXTM3U
                #EXT-X-VERSION:9
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:2
                #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=3
                #EXT-X-PART-INF:PART-TARGET=1
                #EXTINF:4,
                2.ts
                #EXT-X-ENDLIST
                """,
                age: 0
            ),
            for: tuneInURL
        )
        let measuredAt = Date(timeIntervalSince1970: 1_000)
        let client = HLSLivePlaylistClient(
            resolver: PlaylistResolver(session: session),
            configuration: .safeDefaults(),
            now: { measuredAt }
        )
        var snapshots: [HLSLivePlaylistSnapshot] = []

        for try await snapshot in client.snapshots(from: sourceURL) {
            snapshots.append(snapshot)
        }

        #expect(snapshots.count == 1)
        #expect(snapshots.first?.reloadMode == .cdnTuneIn)
        #expect(snapshots.first?.segments.map(\.sequenceNumber) == [2])
        #expect(snapshots.first?.isEnded == true)
    }

    @Test("disabled CDN tune-in performs only the initial request")
    func disablesCDNTuneIn() async throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/cdn-disabled.m3u8")
        )
        let session = makeCDNTuneInSession()
        defer {
            session.invalidateAndCancel()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            cdnTuneInResponse(
                """
                #EXTM3U
                #EXT-X-VERSION:9
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:1
                #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=3
                #EXT-X-PART-INF:PART-TARGET=1
                #EXTINF:4,
                1.ts
                #EXT-X-PRELOAD-HINT:TYPE=PART,URI="2.0.ts"
                """,
                age: 4
            ),
            for: sourceURL
        )
        let snapshot = try await HLSLivePlaylistClient(
            session: session,
            configuration: .advanced(
                cdnTuneIn: HLSLiveCDNTuneInPack(
                    isEnabled: false
                )
            )
        ).snapshot(from: sourceURL)

        #expect(snapshot.reloadMode == .initial)
        #expect(HLSLiveURLProtocol.capturedRequests().count == 1)
    }
}

private func makeCDNTuneInSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HLSLiveURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func cdnTuneInResponse(
    _ playlist: String,
    age: Int
) -> HLSLiveURLProtocol.Response {
    HLSLiveURLProtocol.Response(
        statusCode: 200,
        data: Data(playlist.utf8),
        headers: [
            "Age": String(age),
            "Content-Type": "application/vnd.apple.mpegurl",
        ]
    )
}
