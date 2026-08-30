import CommonCrypto
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

    @Test("AES-128 byte ranges validate ciphertext and retain plaintext")
    func recordsEncryptedByteRange() async throws {
        let sourceURL = try url("https://media.example/encrypted-range.m3u8")
        let keyURL = try url("https://media.example/range.key")
        let segmentURL = try url("https://media.example/range.bin")
        let key = Data(repeating: 0x51, count: 16)
        let initializationVector =
            Data(repeating: 0, count: 15) + Data([5])
        let plaintext = Data("encrypted ranged media".utf8)
        let ciphertext = try aes128Encrypt(
            plaintext,
            key: key,
            initializationVector: initializationVector
        )
        let lowerBound: Int64 = 10
        let upperBound = lowerBound + Int64(ciphertext.count) - 1
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
                #EXT-X-KEY:METHOD=AES-128,URI="range.key",IV=0x00000000000000000000000000000005
                #EXTINF:4,
                #EXT-X-BYTERANGE:\(ciphertext.count)@\(lowerBound)
                range.bin
                #EXT-X-ENDLIST
                """
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(mediaResponse(key), for: keyURL)
        HLSLiveURLProtocol.register(
            HLSLiveURLProtocol.Response(
                statusCode: 206,
                data: ciphertext,
                headers: [
                    "Content-Length": "\(ciphertext.count)",
                    "Content-Range":
                        "bytes \(lowerBound)-\(upperBound)/100",
                ]
            ),
            for: segmentURL
        )

        let receipt = try await recorder(
            session: fixture.session,
            startPosition: .currentWindow
        ).record(from: sourceURL, to: fixture.destinationURL)

        #expect(receipt.mediaByteCount == Int64(plaintext.count))
        #expect(
            try Data(
                contentsOf: receipt.directoryURL
                    .appendingPathComponent("resources/00000.bin")
            ) == plaintext
        )
        let mediaRequest = try #require(
            HLSLiveURLProtocol.capturedRequests().last
        )
        #expect(
            mediaRequest.value(forHTTPHeaderField: "Range")
                == "bytes=\(lowerBound)-\(upperBound)"
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

    @Test("AES-128 media is decrypted into a key-free local package")
    func recordsAES128Media() async throws {
        let sourceURL = try url(
            "https://media.example/encrypted.m3u8"
        )
        let keyURL = try url("https://media.example/key.bin")
        let segmentURL = try url("https://media.example/1.ts")
        let key = Data("0123456789abcdef".utf8)
        let initializationVector =
            Data(repeating: 0, count: 15) + Data([1])
        let plaintext = Data("decrypted live media".utf8)
        let ciphertext = try aes128Encrypt(
            plaintext,
            key: key,
            initializationVector: initializationVector
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
        HLSLiveURLProtocol.register(
            mediaResponse(key),
            for: keyURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(ciphertext),
            for: segmentURL
        )

        let receipt = try await recorder(
            session: fixture.session,
            startPosition: .currentWindow
        ).record(
            from: sourceURL,
            to: fixture.destinationURL
        )

        #expect(receipt.mediaByteCount == Int64(plaintext.count))
        #expect(
            try Data(
                contentsOf: receipt.directoryURL
                    .appendingPathComponent("resources/00000.ts")
            ) == plaintext
        )
        let playlist = try String(
            contentsOf: receipt.playlistURL,
            encoding: .utf8
        )
        #expect(!playlist.contains("#EXT-X-KEY"))
        #expect(!playlist.contains(keyURL.absoluteString))
        #expect(
            HLSLiveURLProtocol.capturedRequests()
                .compactMap(\.url)
                == [sourceURL, keyURL, segmentURL]
        )
        #expect(
            try packageFileNames(receipt.directoryURL)
                .allSatisfy { !$0.contains("ciphertext") }
        )
        #expect(
            try packageFileData(receipt.directoryURL)
                .allSatisfy { $0.range(of: key) == nil }
        )
    }

    @Test("implicit media-sequence IVs reuse one in-memory key")
    func recordsImplicitIVAndReusesKey() async throws {
        let sourceURL = try url("https://media.example/implicit.m3u8")
        let keyURL = try url("https://media.example/implicit-key.bin")
        let firstURL = try url("https://media.example/257.ts")
        let secondURL = try url("https://media.example/258.ts")
        let key = Data(repeating: 0x11, count: 16)
        let firstPlaintext = Data("first implicit segment".utf8)
        let secondPlaintext = Data("second implicit segment".utf8)
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
                #EXT-X-MEDIA-SEQUENCE:257
                #EXT-X-KEY:METHOD=AES-128,URI="implicit-key.bin"
                #EXTINF:4,
                257.ts
                #EXTINF:4,
                258.ts
                #EXT-X-ENDLIST
                """
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(mediaResponse(key), for: keyURL)
        HLSLiveURLProtocol.register(
            mediaResponse(
                try aes128Encrypt(
                    firstPlaintext,
                    key: key,
                    initializationVector: sequenceIV(257)
                )
            ),
            for: firstURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(
                try aes128Encrypt(
                    secondPlaintext,
                    key: key,
                    initializationVector: sequenceIV(258)
                )
            ),
            for: secondURL
        )

        let receipt = try await recorder(
            session: fixture.session,
            startPosition: .currentWindow
        ).record(from: sourceURL, to: fixture.destinationURL)

        #expect(
            try Data(
                contentsOf: receipt.directoryURL
                    .appendingPathComponent("resources/00000.ts")
            ) == firstPlaintext
        )
        #expect(
            try Data(
                contentsOf: receipt.directoryURL
                    .appendingPathComponent("resources/00001.ts")
            ) == secondPlaintext
        )
        #expect(
            HLSLiveURLProtocol.capturedRequests()
                .compactMap(\.url)
                .count { $0 == keyURL } == 1
        )
    }

    @Test("AES-128 key rotation fetches each key once")
    func recordsRotatedAES128Keys() async throws {
        let sourceURL = try url("https://media.example/rotation.m3u8")
        let firstKeyURL = try url("https://media.example/first.key")
        let secondKeyURL = try url("https://media.example/second.key")
        let firstURL = try url("https://media.example/1.ts")
        let secondURL = try url("https://media.example/2.ts")
        let firstKey = Data(repeating: 0x21, count: 16)
        let secondKey = Data(repeating: 0x22, count: 16)
        let initializationVector =
            Data(repeating: 0, count: 15) + Data([9])
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
                #EXT-X-KEY:METHOD=AES-128,URI="first.key",IV=0x00000000000000000000000000000009
                #EXTINF:4,
                1.ts
                #EXT-X-KEY:METHOD=AES-128,URI="second.key",IV=0x00000000000000000000000000000009
                #EXTINF:4,
                2.ts
                #EXT-X-ENDLIST
                """
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(mediaResponse(firstKey), for: firstKeyURL)
        HLSLiveURLProtocol.register(mediaResponse(secondKey), for: secondKeyURL)
        HLSLiveURLProtocol.register(
            mediaResponse(
                try aes128Encrypt(
                    Data("first rotated".utf8),
                    key: firstKey,
                    initializationVector: initializationVector
                )
            ),
            for: firstURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(
                try aes128Encrypt(
                    Data("second rotated".utf8),
                    key: secondKey,
                    initializationVector: initializationVector
                )
            ),
            for: secondURL
        )

        let receipt = try await recorder(
            session: fixture.session,
            startPosition: .currentWindow
        ).record(from: sourceURL, to: fixture.destinationURL)

        #expect(receipt.segmentCount == 2)
        let requests = HLSLiveURLProtocol.capturedRequests().compactMap(\.url)
        #expect(requests.count { $0 == firstKeyURL } == 1)
        #expect(requests.count { $0 == secondKeyURL } == 1)
    }

    @Test("encrypted fragmented MP4 decrypts its map and media")
    func recordsEncryptedFragmentedMP4() async throws {
        let sourceURL = try url("https://media.example/encrypted-fmp4.m3u8")
        let keyURL = try url("https://media.example/fmp4.key")
        let initializationURL = try url("https://media.example/init.mp4")
        let segmentURL = try url("https://media.example/1.m4s")
        let key = Data(repeating: 0x31, count: 16)
        let initializationVector =
            Data(repeating: 0, count: 15) + Data([3])
        let initializationPlaintext = Data("encrypted init".utf8)
        let mediaPlaintext = Data("encrypted fragment".utf8)
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
                #EXT-X-KEY:METHOD=AES-128,URI="fmp4.key",IV=0x00000000000000000000000000000003
                #EXT-X-MAP:URI="init.mp4"
                #EXTINF:4,
                1.m4s
                #EXT-X-ENDLIST
                """
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(mediaResponse(key), for: keyURL)
        HLSLiveURLProtocol.register(
            mediaResponse(
                try aes128Encrypt(
                    initializationPlaintext,
                    key: key,
                    initializationVector: initializationVector
                )
            ),
            for: initializationURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(
                try aes128Encrypt(
                    mediaPlaintext,
                    key: key,
                    initializationVector: initializationVector
                )
            ),
            for: segmentURL
        )

        let receipt = try await recorder(
            session: fixture.session,
            startPosition: .currentWindow
        ).record(from: sourceURL, to: fixture.destinationURL)

        #expect(
            try Data(
                contentsOf: receipt.directoryURL.appendingPathComponent(
                    "resources/initialization.mp4"
                )
            ) == initializationPlaintext
        )
        #expect(
            try Data(
                contentsOf: receipt.directoryURL
                    .appendingPathComponent("resources/00000.m4s")
            ) == mediaPlaintext
        )
    }

    @Test("invalid AES-128 key length fails atomically")
    func rejectsInvalidAES128KeyLength() async throws {
        try await assertAES128Failure(
            keyResponse: mediaResponse(Data(repeating: 0, count: 15)),
            expectedError: .invalidEncryptionKey
        )
    }

    @Test("AES-128 key status failures stay typed")
    func rejectsAES128KeyStatus() async throws {
        try await assertAES128Failure(
            keyResponse: HLSLiveURLProtocol.Response(
                statusCode: 403,
                data: Data(),
                headers: ["Content-Length": "0"]
            ),
            expectedError: .invalidEncryptionKeyResponseStatus(403)
        )
    }

    @Test("invalid AES-128 ciphertext fails atomically")
    func rejectsInvalidAES128Ciphertext() async throws {
        try await assertAES128Failure(
            keyResponse: mediaResponse(Data(repeating: 0x41, count: 16)),
            mediaData: Data(repeating: 0x42, count: 15),
            expectedError: .decryptionFailed
        )
    }

    @Test("SAMPLE-AES is rejected before key or media requests")
    func rejectsSampleAESBeforePersistence() async throws {
        let sourceURL = try url("https://media.example/sample-aes.m3u8")
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
                #EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://asset"
                #EXTINF:4,
                1.ts
                #EXT-X-ENDLIST
                """
            ),
            for: sourceURL
        )

        await #expect(
            throws: HLSLiveDVRError.unsupportedFeature(.encryptedMedia)
        ) {
            try await recorder(
                session: fixture.session,
                startPosition: .currentWindow
            ).record(from: sourceURL, to: fixture.destinationURL)
        }
        #expect(
            HLSLiveURLProtocol.capturedRequests()
                .compactMap(\.url) == [sourceURL]
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.destinationURL.path
            )
        )
    }

    @Test("default external audio is retained behind a URL-free local master")
    func retainsDefaultExternalAudio() async throws {
        let masterURL = try url(
            "https://media.example/master-audio.m3u8"
        )
        let mediaURL = try url(
            "https://media.example/video.m3u8"
        )
        let audioPlaylistURL = try url(
            "https://media.example/audio.m3u8"
        )
        let videoSegmentURL = try url(
            "https://media.example/video.ts?token=video"
        )
        let audioSegmentURL = try url(
            "https://media.example/audio.aac?token=audio"
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
                #EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID="captions",NAME="English CC",LANGUAGE="en",INSTREAM-ID="CC1"
                #EXT-X-STREAM-INF:BANDWIDTH=1000000,CODECS="avc1.4d401f,mp4a.40.2",HDCP-LEVEL=TYPE-0,AUDIO="audio",CLOSED-CAPTIONS="captions",ALLOWED-CPC="com.example.drm:HW"
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
                video.ts?token=video
                #EXT-X-ENDLIST
                """
            ),
            for: mediaURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:1
                #EXTINF:4,
                audio.aac?token=audio
                #EXT-X-ENDLIST
                """
            ),
            for: audioPlaylistURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("video".utf8)),
            for: videoSegmentURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("audio".utf8)),
            for: audioSegmentURL
        )

        let receipt = try await recorder(
            session: fixture.session,
            startPosition: .currentWindow
        ).record(
            from: masterURL,
            to: fixture.destinationURL
        )

        #expect(receipt.entryPlaylistURL.lastPathComponent == "master.m3u8")
        #expect(receipt.playlistURL.lastPathComponent == "index.m3u8")
        #expect(receipt.tracks.map(\.kind) == [.primary, .audio])
        let audioTrack = try #require(receipt.tracks.last)
        let audioPlaylist = try String(
            contentsOf: receipt.directoryURL.appendingPathComponent(
                audioTrack.relativePlaylistPath
            ),
            encoding: .utf8
        )
        let master = try String(
            contentsOf: receipt.entryPlaylistURL,
            encoding: .utf8
        )
        let parsedMaster = try PlaylistResolver().resolve(
            master,
            relativeTo: receipt.entryPlaylistURL
        )
        #expect(master.contains("#EXT-X-MEDIA:TYPE=AUDIO"))
        #expect(master.contains("AUDIO=\"live-dvr-audio\""))
        #expect(master.contains(audioTrack.relativePlaylistPath))
        #expect(audioPlaylist.contains("resources/00000.aac"))
        #expect(!master.contains("media.example"))
        #expect(!master.contains("token="))
        #expect(!master.contains("CODECS"))
        #expect(!master.contains("HDCP-LEVEL"))
        #expect(!master.contains("ALLOWED-CPC"))
        #expect(parsedMaster.kind == .multivariant)
        #expect(parsedMaster.variants.first?.audioGroupID == "live-dvr-audio")
        #expect(parsedMaster.renditions.first?.name == "Stereo")
        #expect(parsedMaster.renditions.last?.name == "English CC")
        #expect(parsedMaster.renditions.last?.url == nil)
        #expect(!audioPlaylist.contains("media.example"))
        #expect(!audioPlaylist.contains("token="))
        #expect(
            HLSLiveURLProtocol.capturedRequests()
                .compactMap(\.url)
                == [
                    masterURL,
                    mediaURL,
                    audioPlaylistURL,
                    audioSegmentURL,
                    videoSegmentURL,
                ]
        )
    }

    @Test("primary and external renditions share the in-memory AES key cache")
    func sharesAES128KeyAcrossRenditions() async throws {
        let masterURL = try url("https://media.example/aes-master.m3u8")
        let videoPlaylistURL = try url(
            "https://media.example/aes-video.m3u8"
        )
        let audioPlaylistURL = try url(
            "https://media.example/aes-audio.m3u8"
        )
        let keyURL = try url("https://media.example/shared.key")
        let videoURL = try url("https://media.example/aes-video.ts")
        let audioURL = try url("https://media.example/aes-audio.aac")
        let key = Data(repeating: 0x71, count: 16)
        let videoPlaintext = Data("encrypted video".utf8)
        let audioPlaintext = Data("encrypted audio".utf8)
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Stereo",DEFAULT=YES,URI="aes-audio.m3u8"
                #EXT-X-STREAM-INF:BANDWIDTH=1000,AUDIO="audio"
                aes-video.m3u8
                """
            ),
            for: masterURL
        )
        let encryptedPlaylist: (String) -> String = { resource in
            """
            #EXTM3U
            #EXT-X-TARGETDURATION:4
            #EXT-X-MEDIA-SEQUENCE:1
            #EXT-X-KEY:METHOD=AES-128,URI="shared.key"
            #EXTINF:4,
            \(resource)
            #EXT-X-ENDLIST
            """
        }
        HLSLiveURLProtocol.register(
            playlistResponse(encryptedPlaylist("aes-video.ts")),
            for: videoPlaylistURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(encryptedPlaylist("aes-audio.aac")),
            for: audioPlaylistURL
        )
        HLSLiveURLProtocol.register(mediaResponse(key), for: keyURL)
        HLSLiveURLProtocol.register(
            mediaResponse(
                try aes128Encrypt(
                    videoPlaintext,
                    key: key,
                    initializationVector: sequenceIV(1)
                )
            ),
            for: videoURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(
                try aes128Encrypt(
                    audioPlaintext,
                    key: key,
                    initializationVector: sequenceIV(1)
                )
            ),
            for: audioURL
        )

        let receipt = try await recorder(
            session: fixture.session,
            startPosition: .currentWindow
        ).record(from: masterURL, to: fixture.destinationURL)

        #expect(
            HLSLiveURLProtocol.capturedRequests().compactMap(\.url)
                .count { $0 == keyURL } == 1
        )
        #expect(
            try Data(
                contentsOf: receipt.directoryURL.appendingPathComponent(
                    "resources/00000.ts"
                )
            ) == videoPlaintext
        )
        let audioTrack = try #require(
            receipt.tracks.first(where: { $0.kind == .audio })
        )
        let audioDirectory = String(
            audioTrack.relativePlaylistPath.dropLast(
                "/index.m3u8".count
            )
        )
        #expect(
            try Data(
                contentsOf: receipt.directoryURL.appendingPathComponent(
                    audioDirectory + "/resources/00000.aac"
                )
            ) == audioPlaintext
        )
    }

    @Test("program time and standard Date Ranges survive local packaging")
    func retainsTimelineMetadata() async throws {
        let sourceURL = try url("https://media.example/timeline.m3u8")
        let firstURL = try url("https://media.example/10.ts")
        let secondURL = try url("https://media.example/11.ts")
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
                #EXT-X-PROGRAM-DATE-TIME:2026-08-30T00:00:00.000Z
                #EXT-X-DATERANGE:ID="chapter-1",CLASS="chapter",START-DATE="2026-08-30T00:00:01.000Z",DURATION=5,PLANNED-DURATION=6,CUE="ONCE"
                #EXTINF:4,
                10.ts
                #EXTINF:4,
                11.ts
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
        ).record(from: sourceURL, to: fixture.destinationURL)
        let localContents = try String(
            contentsOf: receipt.playlistURL,
            encoding: .utf8
        )
        let localPlaylist = try PlaylistResolver().resolve(
            localContents,
            relativeTo: receipt.playlistURL
        )

        #expect(localPlaylist.programDateTimes.count == 2)
        #expect(localPlaylist.dateRanges.count == 1)
        #expect(localPlaylist.dateRanges[0].id == "chapter-1")
        #expect(localPlaylist.dateRanges[0].duration == 5)
        #expect(localPlaylist.dateRanges[0].plannedDuration == 6)
        #expect(localPlaylist.dateRanges[0].cues == [.once])
        #expect(
            localPlaylist.programDateTimes[1].date
                .timeIntervalSince(
                    localPlaylist.programDateTimes[0].date
                ) == 4
        )
    }

    @Test("recorded Date Ranges survive later live-window eviction")
    func retainsEvictedTimelineMetadata() async throws {
        let sourceURL = try url(
            "https://media.example/rolling-timeline.m3u8"
        )
        let reloadURL = try url(
            "https://media.example/rolling-timeline.m3u8?_HLS_msn=2"
        )
        let firstURL = try url("https://media.example/rolling-1.ts")
        let secondURL = try url("https://media.example/rolling-2.ts")
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
                #EXT-X-PROGRAM-DATE-TIME:2026-08-30T00:00:00.000Z
                #EXT-X-DATERANGE:ID="chapter-1",CLASS="chapter",START-DATE="2026-08-30T00:00:00.000Z",DURATION=4
                #EXTINF:4,
                rolling-1.ts
                """
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:2
                #EXT-X-PROGRAM-DATE-TIME:2026-08-30T00:00:04.000Z
                #EXTINF:4,
                rolling-2.ts
                #EXT-X-ENDLIST
                """
            ),
            for: reloadURL
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
        ).record(from: sourceURL, to: fixture.destinationURL)
        let localContents = try String(
            contentsOf: receipt.playlistURL,
            encoding: .utf8
        )
        let localPlaylist = try PlaylistResolver().resolve(
            localContents,
            relativeTo: receipt.playlistURL
        )
        let lines = localContents.components(separatedBy: .newlines)
        let programDateIndex = try #require(
            lines.firstIndex(where: {
                $0.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:")
            })
        )
        let dateRangeIndex = try #require(
            lines.firstIndex(where: {
                $0.hasPrefix("#EXT-X-DATERANGE:")
            })
        )

        #expect(localPlaylist.dateRanges.map(\.id) == ["chapter-1"])
        #expect(programDateIndex < dateRangeIndex)
    }

    @Test("redacted Date Range extension values fail before media persistence")
    func rejectsUnrepresentableTimelineMetadata() async throws {
        let sourceURL = try url(
            "https://media.example/custom-timeline.m3u8"
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
                #EXT-X-PROGRAM-DATE-TIME:2026-08-30T00:00:00.000Z
                #EXT-X-DATERANGE:ID="custom",START-DATE="2026-08-30T00:00:00.000Z",SCTE35-OUT=0xFC
                #EXTINF:4,
                media.ts
                #EXT-X-ENDLIST
                """
            ),
            for: sourceURL
        )

        await #expect(
            throws: HLSLiveDVRError.unsupportedFeature(
                .unrepresentableTimelineMetadata
            )
        ) {
            try await recorder(
                session: fixture.session,
                startPosition: .currentWindow
            ).record(from: sourceURL, to: fixture.destinationURL)
        }
        #expect(
            HLSLiveURLProtocol.capturedRequests().compactMap(\.url)
                == [sourceURL]
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.destinationURL.path
            )
        )
    }

    @Test("external rendition must cover the retained primary timeline")
    func rejectsIncompleteExternalRenditionAtomically() async throws {
        let masterURL = try url("https://media.example/short-master.m3u8")
        let videoPlaylistURL = try url(
            "https://media.example/short-video.m3u8"
        )
        let audioPlaylistURL = try url(
            "https://media.example/short-audio.m3u8"
        )
        let videoURL = try url("https://media.example/short-video.ts")
        let audioURL = try url("https://media.example/short-audio.aac")
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Stereo",DEFAULT=YES,URI="short-audio.m3u8"
                #EXT-X-STREAM-INF:BANDWIDTH=1000,AUDIO="audio"
                short-video.m3u8
                """
            ),
            for: masterURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXTINF:4,
                short-video.ts
                #EXT-X-ENDLIST
                """
            ),
            for: videoPlaylistURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:1
                #EXTINF:1,
                short-audio.aac
                #EXT-X-ENDLIST
                """
            ),
            for: audioPlaylistURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("video".utf8)),
            for: videoURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("audio".utf8)),
            for: audioURL
        )

        await #expect(
            throws: HLSLiveDVRError.unsupportedFeature(
                .incompleteExternalRendition
            )
        ) {
            try await recorder(
                session: fixture.session,
                startPosition: .currentWindow
            ).record(from: masterURL, to: fixture.destinationURL)
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.destinationURL.path
            )
        )
    }

    @Test("preferred subtitle languages retain imported-variable playlists")
    func retainsPreferredSubtitleRenditionsWithImportedVariables() async throws {
        let masterURL = try url("https://media.example/subtitles-master.m3u8")
        let videoPlaylistURL = try url(
            "https://media.example/subtitles-video.m3u8"
        )
        let koreanPlaylistURL = try url(
            "https://media.example/ko.m3u8"
        )
        let englishPlaylistURL = try url(
            "https://media.example/en.m3u8"
        )
        let videoURL = try url("https://media.example/subtitles-video.ts")
        let koreanURL = try url("https://media.example/ko.vtt")
        let englishURL = try url("https://media.example/en.vtt")
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-VERSION:8
                #EXT-X-DEFINE:NAME="KO_RESOURCE",VALUE="ko.vtt"
                #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",LANGUAGE="en",AUTOSELECT=YES,URI="en.m3u8"
                #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="Korean",LANGUAGE="ko",DEFAULT=YES,AUTOSELECT=YES,URI="ko.m3u8"
                #EXT-X-STREAM-INF:BANDWIDTH=1000,SUBTITLES="subs"
                subtitles-video.m3u8
                """
            ),
            for: masterURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXTINF:4,
                subtitles-video.ts
                #EXT-X-ENDLIST
                """
            ),
            for: videoPlaylistURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-VERSION:8
                #EXT-X-DEFINE:IMPORT="KO_RESOURCE"
                #EXT-X-TARGETDURATION:4
                #EXTINF:4,
                {$KO_RESOURCE}
                #EXT-X-ENDLIST
                """
            ),
            for: koreanPlaylistURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXTINF:4,
                en.vtt
                #EXT-X-ENDLIST
                """
            ),
            for: englishPlaylistURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("video".utf8)),
            for: videoURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("WEBVTT\nko".utf8)),
            for: koreanURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("WEBVTT\nen".utf8)),
            for: englishURL
        )

        let receipt = try await recorder(
            session: fixture.session,
            startPosition: .currentWindow,
            renditions: HLSLiveDVRRenditionPack(
                audio: .disabled,
                subtitles: .preferredLanguages(["ko-KR", "en"])
            )
        ).record(from: masterURL, to: fixture.destinationURL)

        #expect(
            receipt.tracks.map(\.kind)
                == [.primary, .subtitles, .subtitles]
        )
        #expect(receipt.tracks.dropFirst().map(\.language) == ["ko", "en"])
        let master = try String(
            contentsOf: receipt.entryPlaylistURL,
            encoding: .utf8
        )
        #expect(
            master.components(separatedBy: "#EXT-X-MEDIA:TYPE=SUBTITLES")
                .count - 1 == 2
        )
        #expect(!master.contains("KO_RESOURCE"))
        #expect(!master.contains("media.example"))
    }

    @Test("stable rendition identity survives Content Steering failover")
    func retainsRenditionAcrossContentSteeringFailover() async throws {
        let masterURL = try url("https://media.example/dvr-steered.m3u8")
        let steeringURL = try url("https://media.example/dvr-steering.json")
        let primaryVideoURL = try url("https://media.example/a-video.m3u8")
        let primaryReloadURL = try url(
            "https://media.example/a-video.m3u8?_HLS_msn=2"
        )
        let primaryAudioURL = try url("https://media.example/a-audio.m3u8")
        let fallbackVideoURL = try url(
            "https://media.example/b-video.m3u8?_HLS_msn=1"
        )
        let fallbackAudioURL = try url("https://media.example/b-audio.m3u8")
        let fallbackVideoSegmentURL = try url(
            "https://media.example/b-video-2.ts"
        )
        let fallbackAudioSegmentURL = try url(
            "https://media.example/b-audio-2.aac"
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
                #EXT-X-CONTENT-STEERING:SERVER-URI="dvr-steering.json",PATHWAY-ID="A"
                #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="English",STABLE-RENDITION-ID="audio-main",DEFAULT=YES,URI="a-audio.m3u8"
                #EXT-X-STREAM-INF:BANDWIDTH=1000,RESOLUTION=1280x720,CODECS="avc1.4d401f",AUDIO="audio",STABLE-VARIANT-ID="video-main",PATHWAY-ID="A"
                a-video.m3u8
                """
            ),
            for: masterURL
        )
        HLSLiveURLProtocol.register(
            HLSLiveURLProtocol.Response(
                statusCode: 200,
                data: Data(
                    """
                    {
                      "VERSION": 1,
                      "TTL": 300,
                      "PATHWAY-PRIORITY": ["A", "B"],
                      "PATHWAY-CLONES": [{
                        "BASE-ID": "A",
                        "ID": "B",
                        "URI-REPLACEMENT": {
                          "PER-VARIANT-URIS": {
                            "video-main": "https://media.example/b-video.m3u8"
                          },
                          "PER-RENDITION-URIS": {
                            "audio-main": "https://media.example/b-audio.m3u8"
                          }
                        }
                      }]
                    }
                    """.utf8
                ),
                headers: ["Content-Type": "application/json"]
            ),
            for: steeringURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-VERSION:9
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:1
                #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES
                #EXTINF:4,
                a-video-1.ts
                #EXT-X-RENDITION-REPORT:URI="b-video.m3u8",LAST-MSN=1
                """
            ),
            for: primaryVideoURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:1
                #EXTINF:4,
                a-audio-1.aac
                """
            ),
            for: primaryAudioURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:2
                #EXTINF:4,
                b-video-2.ts
                #EXT-X-ENDLIST
                """
            ),
            for: fallbackVideoURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:1
                #EXTINF:4,
                b-audio-1.aac
                #EXTINF:4,
                b-audio-2.aac
                #EXT-X-ENDLIST
                """
            ),
            for: fallbackAudioURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("fallback-video".utf8)),
            for: fallbackVideoSegmentURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("fallback-audio".utf8)),
            for: fallbackAudioSegmentURL
        )

        let client = HLSLivePlaylistClient(
            session: fixture.session,
            configuration: .advanced(
                variantSelectionPolicy: .highestQuality,
                contentSteering: HLSContentSteeringPack()
            )
        )
        let receipt = try await HLSLiveDVRRecorder(
            client: client,
            configuration: .advanced(
                limits: HLSLiveDVRLimitPack(
                    maximumDuration: 60,
                    maximumSegmentCount: 20,
                    maximumMediaResourceBytes: 1_024,
                    maximumTotalMediaBytes: 4_096
                ),
                startPosition: .nextCompletedSegment
            )
        ).record(from: masterURL, to: fixture.destinationURL)

        #expect(receipt.segmentCount == 1)
        #expect(receipt.tracks.last?.stableID == "audio-main")
        let requests = HLSLiveURLProtocol.capturedRequests().compactMap(\.url)
        #expect(requests.contains(primaryReloadURL))
        #expect(requests.contains(fallbackVideoURL))
        #expect(requests.contains(fallbackAudioURL))
        #expect(requests.contains(fallbackVideoSegmentURL))
        #expect(requests.contains(fallbackAudioSegmentURL))
    }

    @Test("Content Steering rejects an unreferenced stable rendition")
    func rejectsUnreferencedStableRendition() throws {
        let sourceURL = try url("https://media.example/source-master.m3u8")
        let fallbackURL = try url(
            "https://media.example/fallback-master.m3u8"
        )
        let mediaURL = try url("https://media.example/media.m3u8")
        let source = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio-a",NAME="English",STABLE-RENDITION-ID="audio-main",DEFAULT=YES,URI="a.m3u8"
            #EXT-X-STREAM-INF:BANDWIDTH=1000,AUDIO="audio-a",STABLE-VARIANT-ID="video-main",PATHWAY-ID="A"
            a-video.m3u8
            """,
            relativeTo: sourceURL
        )
        let fallback = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio-a",NAME="Unreferenced",STABLE-RENDITION-ID="audio-main",DEFAULT=YES,URI="wrong.m3u8"
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio-b",NAME="Current",STABLE-RENDITION-ID="audio-current",DEFAULT=YES,URI="current.m3u8"
            #EXT-X-STREAM-INF:BANDWIDTH=1000,AUDIO="audio-b",STABLE-VARIANT-ID="video-main",PATHWAY-ID="B"
            b-video.m3u8
            """,
            relativeTo: fallbackURL
        )
        let media = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-TARGETDURATION:4
            #EXTINF:4,
            media.ts
            """,
            relativeTo: mediaURL
        )
        let sourceSnapshot = HLSLivePlaylistSnapshot(
            playlist: media,
            segments: [],
            partialSegments: [],
            dateRanges: [],
            selectedVariant: source.variants.first,
            availableRenditions: source.renditions,
            pathwayID: "A",
            generation: 0,
            isDeltaUpdate: false,
            isEnded: false
        )
        let fallbackSnapshot = HLSLivePlaylistSnapshot(
            playlist: media,
            segments: [],
            partialSegments: [],
            dateRanges: [],
            selectedVariant: fallback.variants.first,
            availableRenditions: fallback.renditions,
            pathwayID: "B",
            generation: 1,
            isDeltaUpdate: false,
            isEnded: false
        )
        let selection = try HLSLiveDVRRenditionSelector.select(
            from: sourceSnapshot,
            pack: HLSLiveDVRRenditionPack()
        )
        let selected = try #require(selection.external.first)

        #expect(
            throws: HLSLiveDVRError.unsupportedFeature(
                .incompleteExternalRendition
            )
        ) {
            try selected.source(
                in: fallbackSnapshot,
                initialPathwayID: "A"
            )
        }
    }

    @Test("Content Steering retains only proven in-band captions")
    func retainsOnlyProvenInBandCaptions() throws {
        let sourceURL = try url("https://media.example/source-master.m3u8")
        let fallbackURL = try url(
            "https://media.example/fallback-master.m3u8"
        )
        let mediaURL = try url("https://media.example/media.m3u8")
        let source = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID="captions-a",NAME="Stable",STABLE-RENDITION-ID="captions-main",INSTREAM-ID="CC1"
            #EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID="captions-a",NAME="Declared",INSTREAM-ID="CC2"
            #EXT-X-STREAM-INF:BANDWIDTH=1000,CLOSED-CAPTIONS="captions-a",STABLE-VARIANT-ID="video-main",PATHWAY-ID="A"
            a-video.m3u8
            """,
            relativeTo: sourceURL
        )
        let fallback = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID="captions-b",NAME="Stable fallback",STABLE-RENDITION-ID="captions-main",INSTREAM-ID="CC1"
            #EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID="captions-b",NAME="Declared",INSTREAM-ID="CC2"
            #EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID="captions-a",NAME="Unreferenced",STABLE-RENDITION-ID="captions-main",INSTREAM-ID="CC3"
            #EXT-X-STREAM-INF:BANDWIDTH=1000,CLOSED-CAPTIONS="captions-b",STABLE-VARIANT-ID="video-main",PATHWAY-ID="B"
            b-video.m3u8
            """,
            relativeTo: fallbackURL
        )
        let media = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-TARGETDURATION:4
            #EXTINF:4,
            media.ts
            """,
            relativeTo: mediaURL
        )
        let sourceSnapshot = HLSLivePlaylistSnapshot(
            playlist: media,
            segments: [],
            partialSegments: [],
            dateRanges: [],
            selectedVariant: source.variants.first,
            availableRenditions: source.renditions,
            pathwayID: "A",
            generation: 0,
            isDeltaUpdate: false,
            isEnded: false
        )
        let fallbackSnapshot = HLSLivePlaylistSnapshot(
            playlist: media,
            segments: [],
            partialSegments: [],
            dateRanges: [],
            selectedVariant: fallback.variants.first,
            availableRenditions: fallback.renditions,
            pathwayID: "B",
            generation: 1,
            isDeltaUpdate: false,
            isEnded: false
        )
        let selection = try HLSLiveDVRRenditionSelector.select(
            from: sourceSnapshot,
            pack: HLSLiveDVRRenditionPack()
        )

        let retained = HLSLiveDVRRenditionSelector.retainedClosedCaptions(
            selection.inBandClosedCaptions,
            in: fallbackSnapshot,
            initialPathwayID: "A"
        )

        #expect(retained.count == 1)
        #expect(retained.first?.stableID == "captions-main")
        #expect(retained.first?.groupID == "captions-b")
        #expect(retained.first?.instreamID == "CC1")
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

    private func assertAES128Failure(
        keyResponse: HLSLiveURLProtocol.Response,
        mediaData: Data = Data(repeating: 0, count: 16),
        expectedError: HLSLiveDVRError
    ) async throws {
        let sourceURL = try url("https://media.example/failure.m3u8")
        let keyURL = try url("https://media.example/failure.key")
        let segmentURL = try url("https://media.example/failure.ts")
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
                #EXT-X-KEY:METHOD=AES-128,URI="failure.key",IV=0x00000000000000000000000000000001
                #EXTINF:4,
                failure.ts
                #EXT-X-ENDLIST
                """
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(keyResponse, for: keyURL)
        HLSLiveURLProtocol.register(
            mediaResponse(mediaData),
            for: segmentURL
        )

        await #expect(throws: expectedError) {
            try await recorder(
                session: fixture.session,
                startPosition: .currentWindow
            ).record(from: sourceURL, to: fixture.destinationURL)
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.destinationURL.path
            )
        )
        let requests = HLSLiveURLProtocol.capturedRequests().compactMap(\.url)
        switch expectedError {
        case .decryptionFailed:
            #expect(requests == [sourceURL, keyURL, segmentURL])
        default:
            #expect(requests == [sourceURL, keyURL])
        }
    }

    private func packageFileNames(
        _ directoryURL: URL
    ) throws -> [String] {
        try packageFileURLs(directoryURL).map(\.lastPathComponent)
    }

    private func packageFileData(
        _ directoryURL: URL
    ) throws -> [Data] {
        try packageFileURLs(directoryURL).map {
            try Data(contentsOf: $0)
        }
    }

    private func packageFileURLs(
        _ directoryURL: URL
    ) throws -> [URL] {
        let enumerator = try #require(
            FileManager.default.enumerator(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey]
            )
        )
        return try enumerator.compactMap {
            guard let url = $0 as? URL else {
                return nil
            }
            return try url.resourceValues(
                forKeys: [.isRegularFileKey]
            ).isRegularFile == true ? url : nil
        }
    }

    private func recorder(
        session: URLSession,
        startPosition: HLSLiveDVRStartPosition,
        renditions: HLSLiveDVRRenditionPack =
            HLSLiveDVRRenditionPack()
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
                startPosition: startPosition,
                renditions: renditions
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

private func sequenceIV(_ sequenceNumber: Int64) -> Data {
    var value = UInt64(sequenceNumber).bigEndian
    var initializationVector = Data(repeating: 0, count: 8)
    withUnsafeBytes(of: &value) {
        initializationVector.append(contentsOf: $0)
    }
    return initializationVector
}

private func aes128Encrypt(
    _ plaintext: Data,
    key: Data,
    initializationVector: Data
) throws -> Data {
    var ciphertext = Data(
        count: plaintext.count + kCCBlockSizeAES128
    )
    let outputCapacity = ciphertext.count
    var outputLength = 0
    let status = ciphertext.withUnsafeMutableBytes { outputBytes in
        plaintext.withUnsafeBytes { plaintextBytes in
            key.withUnsafeBytes { keyBytes in
                initializationVector.withUnsafeBytes { ivBytes in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress,
                        key.count,
                        ivBytes.baseAddress,
                        plaintextBytes.baseAddress,
                        plaintext.count,
                        outputBytes.baseAddress,
                        outputCapacity,
                        &outputLength
                    )
                }
            }
        }
    }
    guard status == kCCSuccess else {
        throw HLSLiveDVRError.decryptionFailed
    }
    ciphertext.count = outputLength
    return ciphertext
}
