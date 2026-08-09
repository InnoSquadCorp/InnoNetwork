import Foundation
import InnoNetworkHLS
import Testing

@testable import InnoNetworkHLSLive

extension HLSLivePlaylistClientTests {
    @Test("limit packs normalize unsafe values")
    func limitNormalization() {
        let limits = HLSLiveDVRLimitPack(
            maximumDuration: .nan,
            maximumSegmentCount: -1,
            maximumMediaResourceBytes: -1,
            maximumTotalMediaBytes: -1,
            requestTimeout: .infinity
        )

        #expect(limits.maximumDuration == 30 * 60)
        #expect(limits.maximumSegmentCount == 1)
        #expect(limits.maximumMediaResourceBytes == 1)
        #expect(limits.maximumTotalMediaBytes == 1)
        #expect(limits.requestTimeout == 60)
    }

    @Test("current live window commits a URL-free local VOD playlist")
    func recordsCurrentWindow() async throws {
        let sourceURL = try url("https://media.example/current.m3u8")
        let firstURL = try url("https://media.example/10.ts?token=one")
        let secondURL = try url("https://media.example/11.ts?token=two")
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:10
                #EXTINF:4,
                10.ts?token=one
                #EXT-X-DISCONTINUITY
                #EXTINF:3.5,
                11.ts?token=two
                #EXT-X-ENDLIST
                """
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("first".utf8)),
            for: firstURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("second".utf8)),
            for: secondURL
        )

        let receipt = try await recorder(
            session: fixture.session,
            startPosition: .currentWindow
        ).record(
            from: sourceURL,
            to: fixture.destinationURL
        )

        #expect(receipt.segmentCount == 2)
        #expect(receipt.recordedDuration == 7.5)
        #expect(receipt.mediaByteCount == 11)
        #expect(receipt.firstMediaSequence == 10)
        #expect(receipt.lastMediaSequence == 11)
        #expect(
            FileManager.default.fileExists(
                atPath: receipt.playlistURL.path
            )
        )
        let playlist = try String(
            contentsOf: receipt.playlistURL,
            encoding: .utf8
        )
        #expect(playlist.contains("#EXT-X-PLAYLIST-TYPE:VOD"))
        #expect(playlist.contains("#EXT-X-MEDIA-SEQUENCE:10"))
        #expect(playlist.contains("#EXT-X-DISCONTINUITY"))
        #expect(playlist.contains("#EXT-X-ENDLIST"))
        #expect(!playlist.contains("media.example"))
        #expect(!playlist.contains("token="))
        #expect(
            HLSLiveURLProtocol.capturedRequests()
                .compactMap(\.url)
                == [sourceURL, firstURL, secondURL]
        )
    }

    @Test("record-from-now skips the initial live window")
    func recordsNextCompletedSegment() async throws {
        let sourceURL = try url("https://media.example/next.m3u8")
        let reloadURL = try url(
            "https://media.example/next.m3u8?_HLS_msn=2"
        )
        let firstURL = try url("https://media.example/1.ts")
        let secondURL = try url("https://media.example/2.ts")
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:1
                #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES
                #EXTINF:4,
                1.ts
                """
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:1
                #EXTINF:4,
                1.ts
                #EXTINF:4,
                2.ts
                #EXT-X-ENDLIST
                """
            ),
            for: reloadURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("second".utf8)),
            for: secondURL
        )

        let receipt = try await recorder(
            session: fixture.session,
            startPosition: .nextCompletedSegment
        ).record(
            from: sourceURL,
            to: fixture.destinationURL
        )

        #expect(receipt.segmentCount == 1)
        #expect(receipt.firstMediaSequence == 2)
        #expect(receipt.lastMediaSequence == 2)
        let requestedURLs =
            HLSLiveURLProtocol.capturedRequests().compactMap(\.url)
        #expect(requestedURLs == [sourceURL, reloadURL, secondURL])
        #expect(!requestedURLs.contains(firstURL))
    }

    @Test("fragmented MP4 retains one stable initialization map")
    func recordsFragmentedMP4() async throws {
        let sourceURL = try url("https://media.example/fmp4.m3u8")
        let initializationURL = try url(
            "https://media.example/init.mp4"
        )
        let segmentURL = try url("https://media.example/1.m4s")
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-VERSION:7
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:1
                #EXT-X-MAP:URI="init.mp4"
                #EXTINF:4,
                1.m4s
                #EXT-X-ENDLIST
                """
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("init".utf8)),
            for: initializationURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("media".utf8)),
            for: segmentURL
        )

        let receipt = try await recorder(
            session: fixture.session,
            startPosition: .currentWindow
        ).record(
            from: sourceURL,
            to: fixture.destinationURL
        )

        #expect(receipt.mediaByteCount == 9)
        let playlist = try String(
            contentsOf: receipt.playlistURL,
            encoding: .utf8
        )
        #expect(
            playlist.contains(
                "#EXT-X-MAP:URI=\"resources/initialization.mp4\""
            )
        )
        #expect(!playlist.contains(initializationURL.absoluteString))
    }

    @Test("segment count stops recording before another media request")
    func segmentCountStopsRecording() async throws {
        let sourceURL = try url("https://media.example/bounded.m3u8")
        let firstURL = try url("https://media.example/1.ts")
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:1
                #EXTINF:4,
                1.ts
                #EXTINF:4,
                2.ts
                #EXT-X-ENDLIST
                """
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("first".utf8)),
            for: firstURL
        )

        let client = HLSLivePlaylistClient(
            session: fixture.session
        )
        let configuration = HLSLiveDVRConfiguration.advanced(
            limits: HLSLiveDVRLimitPack(
                maximumDuration: 60,
                maximumSegmentCount: 1,
                maximumMediaResourceBytes: 1_024,
                maximumTotalMediaBytes: 1_024
            ),
            startPosition: .currentWindow
        )
        let receipt = try await HLSLiveDVRRecorder(
            client: client,
            configuration: configuration
        ).record(
            from: sourceURL,
            to: fixture.destinationURL
        )

        #expect(receipt.segmentCount == 1)
        #expect(
            HLSLiveURLProtocol.capturedRequests()
                .compactMap(\.url)
                == [sourceURL, firstURL]
        )
    }

    @Test("event streams emit bounded progress and a terminal receipt")
    func eventStreamEmitsProgressAndReceipt() async throws {
        let sourceURL = try url("https://media.example/events.m3u8")
        let segmentURL = try url("https://media.example/event.ts")
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:7
                #EXTINF:4,
                event.ts
                #EXT-X-ENDLIST
                """
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("event".utf8)),
            for: segmentURL
        )

        var events: [HLSLiveDVREvent] = []
        for try await event in recorder(
            session: fixture.session,
            startPosition: .currentWindow
        ).events(
            from: sourceURL,
            to: fixture.destinationURL
        ) {
            events.append(event)
        }

        #expect(events.count == 2)
        #expect(
            events.first
                == .progress(
                    HLSLiveDVRProgress(
                        segmentCount: 1,
                        recordedDuration: 4,
                        mediaByteCount: 5
                    )
                )
        )
        guard case .completed(let receipt) = events.last else {
            Issue.record("Expected a terminal live DVR receipt.")
            return
        }
        #expect(receipt.segmentCount == 1)
        #expect(receipt.firstMediaSequence == 7)
    }

    @Test("byte ranges require exact partial responses")
    func recordsExactByteRange() async throws {
        let sourceURL = try url("https://media.example/range.m3u8")
        let segmentURL = try url("https://media.example/range.ts")
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:1
                #EXTINF:4,
                #EXT-X-BYTERANGE:4@2
                range.ts
                #EXT-X-ENDLIST
                """
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            HLSLiveURLProtocol.Response(
                statusCode: 206,
                data: Data("2345".utf8),
                headers: [
                    "Content-Length": "4",
                    "Content-Range": "bytes 2-5/8",
                ]
            ),
            for: segmentURL
        )

        let receipt = try await recorder(
            session: fixture.session,
            startPosition: .currentWindow
        ).record(
            from: sourceURL,
            to: fixture.destinationURL
        )

        #expect(receipt.mediaByteCount == 4)
        let mediaRequest = try #require(
            HLSLiveURLProtocol.capturedRequests().last
        )
        #expect(
            mediaRequest.value(
                forHTTPHeaderField: "Range"
            ) == "bytes=2-5"
        )
        #expect(
            mediaRequest.value(
                forHTTPHeaderField: "Accept-Encoding"
            ) == "identity"
        )
    }

    @Test("total byte limit commits only complete retained segments")
    func totalByteLimitStopsAtSegmentBoundary() async throws {
        let sourceURL = try url("https://media.example/bytes.m3u8")
        let firstURL = try url("https://media.example/first.ts")
        let secondURL = try url("https://media.example/second.ts")
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:1
                #EXTINF:4,
                first.ts
                #EXTINF:4,
                second.ts
                #EXT-X-ENDLIST
                """
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("first".utf8)),
            for: firstURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("second".utf8)),
            for: secondURL
        )
        let recorder = HLSLiveDVRRecorder(
            client: HLSLivePlaylistClient(
                session: fixture.session
            ),
            configuration: .advanced(
                limits: HLSLiveDVRLimitPack(
                    maximumDuration: 60,
                    maximumSegmentCount: 20,
                    maximumMediaResourceBytes: 1_024,
                    maximumTotalMediaBytes: 6
                ),
                startPosition: .currentWindow
            )
        )

        let receipt = try await recorder.record(
            from: sourceURL,
            to: fixture.destinationURL
        )

        #expect(receipt.segmentCount == 1)
        #expect(receipt.mediaByteCount == 5)
        #expect(
            HLSLiveURLProtocol.capturedRequests()
                .compactMap(\.url)
                == [sourceURL, firstURL, secondURL]
        )
    }

    @Test("encrypted media fails without persisting a partial package")
    func encryptedMediaIsRejected() async throws {
        let sourceURL = try url(
            "https://media.example/encrypted.m3u8"
        )
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:1
                #EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x00000000000000000000000000000001
                #EXTINF:4,
                1.ts
                #EXT-X-ENDLIST
                """
            ),
            for: sourceURL
        )

        await #expect(
            throws:
                HLSLiveDVRError.unsupportedFeature(
                    .encryptedMedia
                )
        ) {
            try await recorder(
                session: fixture.session,
                startPosition: .currentWindow
            ).record(
                from: sourceURL,
                to: fixture.destinationURL
            )
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.destinationURL.path
            )
        )
        #expect(
            HLSLiveURLProtocol.capturedRequests()
                .compactMap(\.url) == [sourceURL]
        )
    }

    @Test("external renditions are rejected before media persistence")
    func externalRenditionsAreRejected() async throws {
        let masterURL = try url(
            "https://media.example/master-audio.m3u8"
        )
        let mediaURL = try url(
            "https://media.example/video.m3u8"
        )
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Stereo",DEFAULT=YES,AUTOSELECT=YES,URI="audio.m3u8"
                #EXT-X-STREAM-INF:BANDWIDTH=1000000,AUDIO="audio"
                video.m3u8
                """
            ),
            for: masterURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:1
                #EXTINF:4,
                video.ts
                #EXT-X-ENDLIST
                """
            ),
            for: mediaURL
        )

        await #expect(
            throws:
                HLSLiveDVRError.unsupportedFeature(
                    .externalRendition
                )
        ) {
            try await recorder(
                session: fixture.session,
                startPosition: .currentWindow
            ).record(
                from: masterURL,
                to: fixture.destinationURL
            )
        }
        #expect(
            HLSLiveURLProtocol.capturedRequests()
                .compactMap(\.url)
                == [masterURL]
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.destinationURL.path
            )
        )
    }

    @Test("an existing destination fails before the playlist request")
    func existingDestinationIsRejected() async throws {
        let sourceURL = try url(
            "https://media.example/existing-destination.m3u8"
        )
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        try FileManager.default.createDirectory(
            at: fixture.destinationURL,
            withIntermediateDirectories: false
        )

        await #expect(
            throws: HLSLiveDVRError.destinationAlreadyExists
        ) {
            try await recorder(
                session: fixture.session,
                startPosition: .currentWindow
            ).record(
                from: sourceURL,
                to: fixture.destinationURL
            )
        }
        #expect(HLSLiveURLProtocol.capturedRequests().isEmpty)
    }

    @Test("a lost live window leaves no partial package")
    func liveWindowAdvanceIsRejectedAtomically() async throws {
        let sourceURL = try url(
            "https://media.example/window-advance.m3u8"
        )
        let reloadURL = try url(
            "https://media.example/window-advance.m3u8?_HLS_msn=2"
        )
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:1
                #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES
                #EXTINF:4,
                1.ts
                """
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:3
                #EXTINF:4,
                3.ts
                #EXT-X-ENDLIST
                """
            ),
            for: reloadURL
        )

        await #expect(throws: HLSLiveDVRError.liveWindowAdvanced) {
            try await recorder(
                session: fixture.session,
                startPosition: .nextCompletedSegment
            ).record(
                from: sourceURL,
                to: fixture.destinationURL
            )
        }
        #expect(
            HLSLiveURLProtocol.capturedRequests()
                .compactMap(\.url) == [sourceURL, reloadURL]
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.destinationURL.path
            )
        )
    }

    private func recorder(
        session: URLSession,
        startPosition: HLSLiveDVRStartPosition
    ) -> HLSLiveDVRRecorder {
        HLSLiveDVRRecorder(
            client: HLSLivePlaylistClient(session: session),
            configuration: .advanced(
                limits: HLSLiveDVRLimitPack(
                    maximumDuration: 60,
                    maximumSegmentCount: 20,
                    maximumMediaResourceBytes: 1_024,
                    maximumTotalMediaBytes: 4_096
                ),
                startPosition: startPosition
            )
        )
    }

    private func makeFixture() throws -> DVRFixture {
        let rootURL =
            FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "InnoNetwork-HLSLiveDVR-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: false
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HLSLiveURLProtocol.self]
        return DVRFixture(
            rootURL: rootURL,
            destinationURL:
                rootURL.appendingPathComponent(
                    "recording",
                    isDirectory: true
                ),
            session: URLSession(configuration: configuration)
        )
    }

    private func playlistResponse(
        _ playlist: String
    ) -> HLSLiveURLProtocol.Response {
        HLSLiveURLProtocol.Response(
            statusCode: 200,
            data: Data(playlist.utf8),
            headers: [
                "Content-Type":
                    "application/vnd.apple.mpegurl"
            ]
        )
    }

    private func mediaResponse(
        _ data: Data
    ) -> HLSLiveURLProtocol.Response {
        HLSLiveURLProtocol.Response(
            statusCode: 200,
            data: data,
            headers: [
                "Content-Length": "\(data.count)",
                "Content-Type": "application/octet-stream",
            ]
        )
    }

    private func url(_ value: String) throws -> URL {
        try #require(URL(string: value))
    }
}

private struct DVRFixture {
    let rootURL: URL
    let destinationURL: URL
    let session: URLSession

    func cleanup() {
        session.invalidateAndCancel()
        try? FileManager.default.removeItem(at: rootURL)
    }
}
