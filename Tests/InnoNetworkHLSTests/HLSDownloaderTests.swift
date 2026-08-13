import Foundation
import InnoNetwork
import Testing
import os

@testable import InnoNetworkHLS

#if canImport(AVFoundation)
import AVFoundation
#endif


@Suite("HLS downloader", .serialized)
struct HLSDownloaderTests {
    @Test("insecure initial URLs fail before transport")
    func insecureInitialURLFailsBeforeTransport() async throws {
        let sourceURL = try #require(
            URL(string: "http://media.example/playlist.m3u8")
        )
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        let directoryURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let destinationURL = directoryURL.appendingPathComponent(
            "rejected.ts"
        )

        let event = await terminalEvent(
            from: HLSDownloader(
                session: session,
                configuration: .advanced(
                    storage: HLSStoragePack(
                        diskCapacityPolicy: .disabled
                    )
                )
            ).download(
                sourceURL: sourceURL,
                destinationURL: destinationURL
            )
        )

        guard case .failed(.transferFailed(let underlying)) = event else {
            Issue.record("Expected a typed URL-admission failure.")
            return
        }
        #expect(underlying.domain == NetworkError.errorDomain)
        #expect(
            !HLSURLProtocol.capturedRequests().contains {
                $0.url == sourceURL
            }
        )
        #expect(!FileManager.default.fileExists(atPath: destinationURL.path))
    }

    @Test("request adapters cannot bypass URL admission")
    func requestAdapterCannotBypassURLAdmission() async throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/playlist.m3u8")
        )
        let insecureURL = try #require(
            URL(string: "http://media.example/playlist.m3u8")
        )
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        let directoryURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let destinationURL = directoryURL.appendingPathComponent(
            "adapter-rejected.ts"
        )

        let event = await terminalEvent(
            from: HLSDownloader(
                session: session,
                configuration: .advanced(
                    storage: HLSStoragePack(
                        diskCapacityPolicy: .disabled
                    )
                ),
                requestAdapter: { request in
                    var request = request
                    request.url = insecureURL
                    return request
                }
            ).download(
                sourceURL: sourceURL,
                destinationURL: destinationURL
            )
        )

        guard case .failed(.transferFailed(let underlying)) = event else {
            Issue.record("Expected adapted URL admission to fail.")
            return
        }
        #expect(underlying.domain == NetworkError.errorDomain)
        #expect(
            !HLSURLProtocol.capturedRequests().contains {
                $0.url == sourceURL || $0.url == insecureURL
            }
        )
        #expect(!FileManager.default.fileExists(atPath: destinationURL.path))
    }

    @Test("redirected playlists use the final URL as their base")
    func redirectedPlaylistUsesFinalURL() async throws {
        let initialURL = try #require(
            URL(string: "https://origin.example/entry/master.m3u8")
        )
        let finalURL = try #require(
            URL(string: "https://cdn.example/final/master.m3u8")
        )
        let segmentURL = try #require(
            URL(string: "https://cdn.example/final/segment.ts")
        )
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        HLSURLProtocol.register(
            .redirect(statusCode: 302, location: finalURL),
            for: initialURL
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    """
                    #EXTM3U
                    #EXTINF:1,
                    segment.ts
                    #EXT-X-ENDLIST

                    """.utf8
                ),
                headers: [:]
            ),
            for: finalURL
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data("segment".utf8),
                headers: [:]
            ),
            for: segmentURL
        )
        let directoryURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let destinationURL = directoryURL.appendingPathComponent(
            "redirect.ts"
        )

        let terminalEvent = await terminalEvent(
            from: HLSDownloader(session: session).download(
                sourceURL: initialURL,
                destinationURL: destinationURL
            )
        )

        guard case .completed = terminalEvent else {
            Issue.record("Expected redirected download to complete.")
            return
        }
        #expect(
            try Data(contentsOf: destinationURL)
                == Data("segment".utf8)
        )
        #expect(
            HLSURLProtocol.capturedRequests().compactMap(\.url)
                == [initialURL, finalURL, segmentURL]
        )
    }

    @Test("playlist variable imports flow from multivariant to media playlists")
    func playlistVariableImportsFlowToMediaPlaylist() async throws {
        let masterURL = try #require(
            URL(string: "https://media.example/master.m3u8")
        )
        let mediaURL = try #require(
            URL(string: "https://media.example/video/index.m3u8")
        )
        let segmentURL = try #require(
            URL(string: "https://media.example/media/video.ts")
        )
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    """
                    #EXTM3U
                    #EXT-X-VERSION:8
                    #EXT-X-DEFINE:NAME="track",VALUE="video"
                    #EXT-X-STREAM-INF:BANDWIDTH=1000
                    {$track}/index.m3u8

                    """.utf8
                ),
                headers: [:]
            ),
            for: masterURL
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    """
                    #EXTM3U
                    #EXT-X-VERSION:8
                    #EXT-X-DEFINE:IMPORT="track"
                    #EXTINF:1,
                    ../media/{$track}.ts
                    #EXT-X-ENDLIST

                    """.utf8
                ),
                headers: [:]
            ),
            for: mediaURL
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data("segment".utf8),
                headers: [:]
            ),
            for: segmentURL
        )
        let directoryURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let destinationURL = directoryURL.appendingPathComponent(
            "variables.ts"
        )

        let event = await terminalEvent(
            from: HLSDownloader(session: session).download(
                sourceURL: masterURL,
                destinationURL: destinationURL
            )
        )

        guard case .completed = event else {
            Issue.record("Expected imported playlist variable download to complete.")
            return
        }
        #expect(try Data(contentsOf: destinationURL) == Data("segment".utf8))
        #expect(
            HLSURLProtocol.capturedRequests().compactMap(\.url)
                == [masterURL, mediaURL, segmentURL]
        )
    }

    @Test("query variables use the redirected playlist URL")
    func queryVariablesUseRedirectedPlaylistURL() async throws {
        let initialURL = try #require(
            URL(string: "https://origin.example/master.m3u8?token=old")
        )
        let finalURL = try #require(
            URL(
                string:
                    "https://cdn.example/final/index.m3u8?token=signed%2Fvalue"
            )
        )
        let segmentURL = try #require(
            URL(
                string:
                    "https://cdn.example/final/segment.ts?token=signed/value"
            )
        )
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        HLSURLProtocol.register(
            .redirect(statusCode: 302, location: finalURL),
            for: initialURL
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    """
                    #EXTM3U
                    #EXT-X-VERSION:11
                    #EXT-X-DEFINE:QUERYPARAM="token"
                    #EXTINF:1,
                    segment.ts?token={$token}
                    #EXT-X-ENDLIST

                    """.utf8
                ),
                headers: [:]
            ),
            for: finalURL
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data("segment".utf8),
                headers: [:]
            ),
            for: segmentURL
        )
        let directoryURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let destinationURL = directoryURL.appendingPathComponent(
            "query-variable.ts"
        )

        let event = await terminalEvent(
            from: HLSDownloader(session: session).download(
                sourceURL: initialURL,
                destinationURL: destinationURL
            )
        )

        guard case .completed = event else {
            Issue.record("Expected redirected query variable download to complete.")
            return
        }
        #expect(try Data(contentsOf: destinationURL) == Data("segment".utf8))
    }

    @Test("prepare describes selection without fetching media bytes")
    func prepareDescribesSelectedMedia() async throws {
        let masterURL = try #require(
            URL(string: "https://media.example/master.m3u8")
        )
        let mediaURL = try #require(
            URL(string: "https://media.example/supported.m3u8")
        )
        let resourceURL = try #require(
            URL(string: "https://media.example/media.ts")
        )
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    """
                    #EXTM3U
                    #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="한국어",LANGUAGE="ko",URI="subs.m3u8"
                    #EXT-X-STREAM-INF:BANDWIDTH=7000000,RESOLUTION=3840x2160,CODECS="av01.0.12M.10"
                    unsupported.m3u8
                    #EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1920x1080,CODECS="hvc1.1.6.L120,mp4a.40.2",SUBTITLES="subs"
                    supported.m3u8

                    """.utf8
                ),
                headers: [:]
            ),
            for: masterURL
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    """
                    #EXTM3U
                    #EXT-X-BYTERANGE:3@0
                    #EXTINF:1,
                    media.ts
                    #EXT-X-BYTERANGE:3
                    #EXTINF:1,
                    media.ts
                    #EXT-X-ENDLIST

                    """.utf8
                ),
                headers: [:]
            ),
            for: mediaURL
        )
        let downloader = HLSDownloader(
            session: session,
            configuration: .advanced(
                storage: HLSStoragePack(diskCapacityPolicy: .disabled),
                variantSelectionPolicy: .compatible(
                    HLSPlaybackCapabilities(
                        maximumWidth: 1_920,
                        supportedCodecPrefixes: ["hvc1", "mp4a"]
                    )
                )
            )
        )

        let preparation = try await downloader.prepare(sourceURL: masterURL)

        #expect(preparation.sourceURL == masterURL)
        #expect(preparation.mediaPlaylistURL == mediaURL)
        #expect(preparation.selectedVariant?.url == mediaURL)
        #expect(preparation.availableRenditions.count == 1)
        #expect(preparation.availableRenditions.first?.language == "ko")
        #expect(preparation.mediaContainer == .mpegTransportStream)
        #expect(preparation.segmentCount == 2)
        #expect(preparation.resourceTransferCount == 1)
        #expect(
            HLSURLProtocol.capturedRequests().compactMap(\.url)
                == [masterURL, mediaURL]
        )
        #expect(
            !HLSURLProtocol.capturedRequests().contains {
                $0.url == resourceURL
            }
        )
    }

    @Test("downloadReceipt describes the committed file")
    func downloadReceiptDescribesCommittedFile() async throws {
        let playlistURL = try #require(
            URL(string: "https://media.example/playlist.m3u8")
        )
        let segmentURL = try #require(
            URL(string: "https://media.example/segment.ts")
        )
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        registerMediaPlaylist(
            at: playlistURL,
            resourceNames: ["segment.ts"]
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data("receipt".utf8),
                headers: ["Content-Length": "7"]
            ),
            for: segmentURL
        )
        let directoryURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let destinationURL = directoryURL.appendingPathComponent(
            "receipt.ts"
        )

        let receipt = try await HLSDownloader(
            session: session,
            configuration: .advanced(
                storage: HLSStoragePack(diskCapacityPolicy: .disabled)
            )
        ).downloadReceipt(
            sourceURL: playlistURL,
            destinationURL: destinationURL
        )

        #expect(receipt.destinationURL == destinationURL)
        #expect(receipt.byteCount == 7)
        #expect(receipt.mediaContainer == .mpegTransportStream)
        #expect(receipt.selectedVariant == nil)
        #expect(receipt.resumedResourceTransferCount == 0)
        #expect(try Data(contentsOf: destinationURL) == Data("receipt".utf8))
    }

    @Test("downloadFile returns the committed URL without event handling")
    func downloadFileReturnsCommittedURL() async throws {
        let playlistURL = try #require(
            URL(string: "https://media.example/playlist.m3u8")
        )
        let segmentURL = try #require(
            URL(string: "https://media.example/segment.ts")
        )
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        registerMediaPlaylist(
            at: playlistURL,
            resourceNames: ["segment.ts"]
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data("one-shot".utf8),
                headers: ["Content-Length": "8"]
            ),
            for: segmentURL
        )
        let directoryURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let destinationURL = directoryURL.appendingPathComponent(
            "one-shot.ts"
        )

        let completedURL = try await HLSDownloader(
            session: session,
            configuration: .advanced(
                storage: HLSStoragePack(diskCapacityPolicy: .disabled)
            )
        ).downloadFile(
            sourceURL: playlistURL,
            destinationURL: destinationURL
        )

        #expect(completedURL == destinationURL)
        #expect(try Data(contentsOf: completedURL) == Data("one-shot".utf8))
    }

    @Test("downloadFile throws the same typed terminal failure")
    func downloadFileThrowsTypedFailure() async throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/playlist.m3u8")
        )
        let destinationURL = try #require(
            URL(string: "https://files.example/output.ts")
        )

        do {
            _ = try await HLSDownloader().downloadFile(
                sourceURL: sourceURL,
                destinationURL: destinationURL
            )
            Issue.record("Expected a typed invalid-destination failure.")
        } catch let error as HLSDownloadError {
            #expect(error == .invalidDestination)
        }
    }

    @Test("changing EXT-X-MAP fails before media transfer")
    func changingInitializationMapsFailBeforeMediaTransfer() async throws {
        let playlistURL = try #require(
            URL(string: "https://media.example/playlist.m3u8")
        )
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    """
                    #EXTM3U
                    #EXT-X-MAP:URI="init-1.mp4"
                    #EXTINF:1,
                    segment-1.m4s
                    #EXT-X-MAP:URI="init-2.mp4"
                    #EXTINF:1,
                    segment-2.m4s
                    #EXT-X-ENDLIST

                    """.utf8
                ),
                headers: [:]
            ),
            for: playlistURL
        )
        let directoryURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let destinationURL = directoryURL.appendingPathComponent(
            "maps.mp4"
        )

        let terminalEvent = await terminalEvent(
            from: HLSDownloader(session: session).download(
                sourceURL: playlistURL,
                destinationURL: destinationURL
            )
        )

        guard
            case .failed(
                .unsupportedMediaFeature(
                    .multipleInitializationSections
                )
            ) = terminalEvent
        else {
            Issue.record("Expected changing maps to fail safely.")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: destinationURL.path))
        #expect(
            HLSURLProtocol.capturedRequests().compactMap(\.url)
                == [playlistURL]
        )
    }

    @Test("single-file assembly still rejects I-frame-only media")
    func singleFileAssemblyRejectsIFrameOnlyMedia() async throws {
        let playlistURL = try #require(
            URL(string: "https://media.example/iframe.m3u8")
        )
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    """
                    #EXTM3U
                    #EXT-X-VERSION:4
                    #EXT-X-I-FRAMES-ONLY
                    #EXTINF:1,
                    iframe.ts
                    #EXT-X-ENDLIST

                    """.utf8
                ),
                headers: [:]
            ),
            for: playlistURL
        )

        await #expect(
            throws: HLSDownloadError.unsupportedMediaFeature(
                .iFramesOnly
            )
        ) {
            try await HLSDownloader(session: session).prepare(
                sourceURL: playlistURL
            )
        }
        #expect(
            HLSURLProtocol.capturedRequests().compactMap(\.url)
                == [playlistURL]
        )
    }

    #if canImport(AVFoundation)
    @Test("assembled fMP4 is playable by AVFoundation")
    func assembledFragmentedMP4IsPlayable() async throws {
        let playlistURL = try #require(
            URL(string: "https://media.example/fixture/playlist.m3u8")
        )
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    HLSMediaFixtures.fragmentedMP4Playlist.utf8
                ),
                headers: [:]
            ),
            for: playlistURL
        )
        let resources: [(String, Data)] = [
            ("init.mp4", try HLSMediaFixtures.fragmentedMP4Initialization()),
            ("segment-0.m4s", try HLSMediaFixtures.fragmentedMP4Segment0()),
            ("segment-1.m4s", try HLSMediaFixtures.fragmentedMP4Segment1()),
        ]
        for (name, data) in resources {
            HLSURLProtocol.register(
                .success(
                    statusCode: 200,
                    data: data,
                    headers: ["Content-Length": "\(data.count)"]
                ),
                for:
                    playlistURL
                    .deletingLastPathComponent()
                    .appendingPathComponent(name)
            )
        }
        let directoryURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let destinationURL = directoryURL.appendingPathComponent(
            "playable.mp4"
        )

        let completedURL = try await HLSDownloader(
            session: session,
            configuration: .advanced(
                storage: HLSStoragePack(diskCapacityPolicy: .disabled)
            )
        ).downloadFile(
            sourceURL: playlistURL,
            destinationURL: destinationURL
        )
        let asset = AVURLAsset(url: completedURL)

        try await assertReadableVideoAsset(asset)
        let duration = try await asset.load(.duration)
        #expect(duration.seconds > 2)
    }

    @Test("assembled MPEG transport stream is playable by AVFoundation")
    func assembledTransportStreamIsPlayable() async throws {
        let playlistURL = try #require(
            URL(string: "https://media.example/fixture/playlist.m3u8")
        )
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    HLSMediaFixtures.transportStreamPlaylist.utf8
                ),
                headers: [:]
            ),
            for: playlistURL
        )
        let resources: [(String, Data)] = [
            ("segment-0.ts", try HLSMediaFixtures.transportStreamSegment0())
        ]
        for (name, data) in resources {
            HLSURLProtocol.register(
                .success(
                    statusCode: 200,
                    data: data,
                    headers: ["Content-Length": "\(data.count)"]
                ),
                for:
                    playlistURL
                    .deletingLastPathComponent()
                    .appendingPathComponent(name)
            )
        }
        let directoryURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let destinationURL = directoryURL.appendingPathComponent(
            "playable.ts"
        )

        let completedURL = try await HLSDownloader(
            session: session,
            configuration: .advanced(
                storage: HLSStoragePack(diskCapacityPolicy: .disabled)
            )
        ).downloadFile(
            sourceURL: playlistURL,
            destinationURL: destinationURL
        )
        let asset = AVURLAsset(url: completedURL)

        try await assertReadableVideoAsset(asset)
    }
    #endif

    #if canImport(AVFoundation)
    @Test("contiguous CMAF ranges form an AVFoundation-readable asset")
    func contiguousRangesAreCoalesced() async throws {
        let playlistURL = try #require(
            URL(string: "https://media.example/fixture/playlist.m3u8")
        )
        let mediaURL = try #require(
            URL(string: "https://media.example/fixture/media.mp4")
        )
        let initialization =
            try HLSMediaFixtures.fragmentedMP4Initialization()
        let segment0 = try HLSMediaFixtures.fragmentedMP4Segment0()
        let segment1 = try HLSMediaFixtures.fragmentedMP4Segment1()
        var media = Data()
        media.append(initialization)
        media.append(segment0)
        media.append(segment1)
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    """
                    #EXTM3U
                    #EXT-X-VERSION:7
                    #EXT-X-TARGETDURATION:1
                    #EXT-X-PLAYLIST-TYPE:VOD
                    #EXT-X-MAP:URI="media.mp4",BYTERANGE="\(initialization.count)@0"
                    #EXT-X-BYTERANGE:\(segment0.count)@\(initialization.count)
                    #EXTINF:1,
                    media.mp4
                    #EXT-X-BYTERANGE:\(segment1.count)
                    #EXTINF:1,
                    media.mp4
                    #EXT-X-ENDLIST

                    """.utf8
                ),
                headers: [:]
            ),
            for: playlistURL
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 206,
                data: media,
                headers: [
                    "Content-Length": "\(media.count)",
                    "Content-Range":
                        "bytes 0-\(media.count - 1)/\(media.count)",
                ]
            ),
            for: mediaURL
        )
        let directoryURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let destinationURL = directoryURL.appendingPathComponent(
            "coalesced.mp4"
        )

        let completedURL = try await HLSDownloader(
            session: session,
            configuration: .advanced(
                storage: HLSStoragePack(diskCapacityPolicy: .disabled)
            )
        ).downloadFile(
            sourceURL: playlistURL,
            destinationURL: destinationURL
        )

        #expect(try Data(contentsOf: destinationURL) == media)
        let requests = HLSURLProtocol.capturedRequests()
        #expect(requests.compactMap(\.url) == [playlistURL, mediaURL])
        #expect(
            requests.last?.value(forHTTPHeaderField: "Range")
                == "bytes=0-\(media.count - 1)"
        )
        #expect(
            requests.last?.value(forHTTPHeaderField: "Accept-Encoding")
                == "identity"
        )
        let asset = AVURLAsset(url: completedURL)
        try await assertReadableVideoAsset(asset)
        let duration = try await asset.load(.duration)
        #expect(duration.seconds > 2)
    }
    #endif

    @Test("ranged responses preserve HTTP failures and require exact metadata")
    func rangedResponsesRequireExactMetadata() async throws {
        let playlistURL = try #require(
            URL(string: "https://media.example/playlist.m3u8")
        )
        let mediaURL = try #require(
            URL(string: "https://media.example/media.ts")
        )
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    """
                    #EXTM3U
                    #EXT-X-BYTERANGE:4@0
                    #EXTINF:1,
                    media.ts
                    #EXT-X-ENDLIST

                    """.utf8
                ),
                headers: [:]
            ),
            for: playlistURL
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data("FULL".utf8),
                headers: ["Content-Length": "4"]
            ),
            for: mediaURL
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 206,
                data: Data("WRNG".utf8),
                headers: [
                    "Content-Length": "4",
                    "Content-Range": "bytes 1-4/5",
                ]
            ),
            for: mediaURL
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 206,
                data: Data("EXTRA".utf8),
                headers: ["Content-Range": "bytes 0-3/5"]
            ),
            for: mediaURL
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 503,
                data: Data(),
                headers: [:]
            ),
            for: mediaURL
        )
        let directoryURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let downloader = HLSDownloader(
            session: session,
            configuration: retryTestConfiguration(maxRetries: 0)
        )
        for index in 0..<4 {
            let destinationURL = directoryURL.appendingPathComponent(
                "invalid-range-\(index).ts"
            )
            let event = await terminalEvent(
                from: downloader.download(
                    sourceURL: playlistURL,
                    destinationURL: destinationURL
                )
            )
            if index < 3 {
                guard case .failed(.invalidByteRangeResponse) = event else {
                    Issue.record(
                        "Expected exact byte-range validation to fail."
                    )
                    return
                }
            } else {
                guard
                    case .failed(.invalidMediaResponseStatus(503)) = event
                else {
                    Issue.record("Expected HTTP status classification.")
                    return
                }
            }
            #expect(
                !FileManager.default.fileExists(
                    atPath: destinationURL.path
                )
            )
        }

        let rangeRequests = HLSURLProtocol.capturedRequests().filter {
            $0.url == mediaURL
        }
        #expect(rangeRequests.count == 4)
        #expect(
            rangeRequests.allSatisfy {
                $0.value(forHTTPHeaderField: "Range") == "bytes=0-3"
                    && $0.value(forHTTPHeaderField: "Accept-Encoding")
                        == "identity"
            }
        )
    }

    @Test("URI-less audio renditions are treated as in-band")
    func uriLessAudioRenditionIsInBand() async throws {
        let masterURL = try #require(
            URL(string: "https://media.example/master.m3u8")
        )
        let mediaURL = try #require(
            URL(string: "https://media.example/media.m3u8")
        )
        let segmentURL = try #require(
            URL(string: "https://media.example/segment.ts")
        )
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    """
                    #EXTM3U
                    #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="muxed",NAME="Main",DEFAULT=YES
                    #EXT-X-STREAM-INF:BANDWIDTH=1000000,AUDIO="muxed"
                    media.m3u8

                    """.utf8
                ),
                headers: [:]
            ),
            for: masterURL
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    """
                    #EXTM3U
                    #EXTINF:1,
                    segment.ts
                    #EXT-X-ENDLIST

                    """.utf8
                ),
                headers: [:]
            ),
            for: mediaURL
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data("muxed-audio-video".utf8),
                headers: [:]
            ),
            for: segmentURL
        )
        let directoryURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let destinationURL = directoryURL.appendingPathComponent(
            "muxed.ts"
        )

        let terminalEvent = await terminalEvent(
            from: HLSDownloader(session: session).download(
                sourceURL: masterURL,
                destinationURL: destinationURL
            )
        )

        guard case .completed = terminalEvent else {
            Issue.record("Expected in-band audio download to complete.")
            return
        }
        #expect(
            try Data(contentsOf: destinationURL)
                == Data("muxed-audio-video".utf8)
        )
    }

    @Test("supported variants are preferred over separate-audio variants")
    func separateAudioVariantFallsBackToMuxedVariant() async throws {
        let masterURL = try #require(
            URL(string: "https://media.example/master.m3u8")
        )
        let muxedMediaURL = try #require(
            URL(string: "https://media.example/muxed.m3u8")
        )
        let segmentURL = try #require(
            URL(string: "https://media.example/segment.ts")
        )
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    """
                    #EXTM3U
                    #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="external",NAME="Audio",URI="audio.m3u8"
                    #EXT-X-STREAM-INF:BANDWIDTH=4000000,RESOLUTION=1920x1080,AUDIO="external"
                    video-only.m3u8
                    #EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=1280x720
                    muxed.m3u8

                    """.utf8
                ),
                headers: [:]
            ),
            for: masterURL
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    """
                    #EXTM3U
                    #EXTINF:1,
                    segment.ts
                    #EXT-X-ENDLIST

                    """.utf8
                ),
                headers: [:]
            ),
            for: muxedMediaURL
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data("muxed".utf8),
                headers: [:]
            ),
            for: segmentURL
        )
        let directoryURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let destinationURL = directoryURL.appendingPathComponent(
            "fallback.ts"
        )

        let terminalEvent = await terminalEvent(
            from: HLSDownloader(session: session).download(
                sourceURL: masterURL,
                destinationURL: destinationURL
            )
        )

        guard case .completed = terminalEvent else {
            Issue.record("Expected muxed fallback variant to complete.")
            return
        }
        #expect(
            HLSURLProtocol.capturedRequests().compactMap(\.url)
                == [masterURL, muxedMediaURL, segmentURL]
        )
    }

    @Test("downloader applies the configured variant selection policy")
    func downloaderAppliesVariantSelectionPolicy() async throws {
        let masterURL = try #require(
            URL(string: "https://media.example/master.m3u8")
        )
        let lowMediaURL = try #require(
            URL(string: "https://media.example/low.m3u8")
        )
        let segmentURL = try #require(
            URL(string: "https://media.example/low-segment.ts")
        )
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    """
                    #EXTM3U
                    #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
                    high.m3u8
                    #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=854x480
                    low.m3u8

                    """.utf8
                ),
                headers: [:]
            ),
            for: masterURL
        )
        registerMediaPlaylist(
            at: lowMediaURL,
            resourceNames: ["low-segment.ts"]
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data("low".utf8),
                headers: ["Content-Length": "3"]
            ),
            for: segmentURL
        )
        let directoryURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let destinationURL = directoryURL.appendingPathComponent("low.ts")
        let configuration = HLSDownloadConfiguration.advanced(
            storage: HLSStoragePack(diskCapacityPolicy: .disabled),
            variantSelectionPolicy: .maximumBandwidth(1_000_000),
            transfer: HLSTransferPack(retryPolicy: nil)
        )

        let event = await terminalEvent(
            from: HLSDownloader(
                session: session,
                configuration: configuration
            ).download(
                sourceURL: masterURL,
                destinationURL: destinationURL
            )
        )

        guard case .completed = event else {
            Issue.record("Expected the constrained variant to complete.")
            return
        }
        #expect(
            HLSURLProtocol.capturedRequests().compactMap(\.url)
                == [masterURL, lowMediaURL, segmentURL]
        )
    }

    @Test("downloader applies capability-aware variant selection")
    func downloaderAppliesPlaybackCapabilities() async throws {
        let masterURL = try #require(
            URL(string: "https://media.example/master.m3u8")
        )
        let supportedMediaURL = try #require(
            URL(string: "https://media.example/supported.m3u8")
        )
        let segmentURL = try #require(
            URL(string: "https://media.example/supported-segment.ts")
        )
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    """
                    #EXTM3U
                    #EXT-X-STREAM-INF:BANDWIDTH=7000000,RESOLUTION=3840x2160,CODECS="av01.0.12M.10",VIDEO-RANGE=PQ
                    unsupported.m3u8
                    #EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1920x1080,CODECS="hvc1.1.6.L120,mp4a.40.2",VIDEO-RANGE=SDR
                    supported.m3u8

                    """.utf8
                ),
                headers: [:]
            ),
            for: masterURL
        )
        registerMediaPlaylist(
            at: supportedMediaURL,
            resourceNames: ["supported-segment.ts"]
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data("supported".utf8),
                headers: ["Content-Length": "9"]
            ),
            for: segmentURL
        )
        let directoryURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let destinationURL = directoryURL.appendingPathComponent(
            "supported.ts"
        )
        let configuration = HLSDownloadConfiguration.advanced(
            storage: HLSStoragePack(diskCapacityPolicy: .disabled),
            variantSelectionPolicy: .compatible(
                HLSPlaybackCapabilities(
                    maximumWidth: 1_920,
                    maximumHeight: 1_080,
                    supportedCodecPrefixes: ["hvc1", "mp4a"]
                )
            ),
            transfer: HLSTransferPack(retryPolicy: nil)
        )

        let event = await terminalEvent(
            from: HLSDownloader(
                session: session,
                configuration: configuration
            ).download(
                sourceURL: masterURL,
                destinationURL: destinationURL
            )
        )

        guard case .completed = event else {
            Issue.record("Expected a compatible variant to complete.")
            return
        }
        #expect(
            HLSURLProtocol.capturedRequests().compactMap(\.url)
                == [masterURL, supportedMediaURL, segmentURL]
        )
        #expect(try Data(contentsOf: destinationURL) == Data("supported".utf8))
    }

    @Test("same-destination downloads fail before sharing a partial file")
    func concurrentDestinationIsRejected() async throws {
        let playlistURL = try #require(
            URL(string: "https://media.example/playlist.m3u8")
        )
        let segmentURL = try #require(
            URL(string: "https://media.example/segment.ts")
        )
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    """
                    #EXTM3U
                    #EXTINF:1,
                    segment.ts
                    #EXT-X-ENDLIST

                    """.utf8
                ),
                headers: [:]
            ),
            for: playlistURL
        )
        HLSURLProtocol.register(
            .unfinished(
                statusCode: 200,
                data: Data("partial".utf8),
                headers: [:]
            ),
            for: segmentURL
        )
        let directoryURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let destinationURL = directoryURL.appendingPathComponent(
            "shared.ts"
        )
        let downloader = HLSDownloader(session: session)
        let (progressStream, progressContinuation) =
            AsyncStream<Void>.makeStream(
                bufferingPolicy: .bufferingNewest(1)
            )
        let firstTask = Task {
            for await event in downloader.download(
                sourceURL: playlistURL,
                destinationURL: destinationURL
            ) {
                if case .progress(let progress) = event,
                    progress.totalBytesWritten == 0
                {
                    progressContinuation.yield()
                }
            }
        }
        var progressIterator = progressStream.makeAsyncIterator()
        _ = await progressIterator.next()

        let secondEvent = await terminalEvent(
            from: downloader.download(
                sourceURL: playlistURL,
                destinationURL: destinationURL
            )
        )

        #expect(
            {
                if case .failed(.destinationInUse) = secondEvent {
                    return true
                }
                return false
            }())
        firstTask.cancel()
        await firstTask.value
        #expect(!FileManager.default.fileExists(atPath: destinationURL.path))
    }

    @Test("an OS destination lease blocks another downloader")
    func crossProcessDestinationLeaseIsRejected() async throws {
        let playlistURL = try #require(
            URL(
                string:
                    "https://cross-process-lease.example/playlist.m3u8"
            )
        )
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        let directoryURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let destinationURL = directoryURL.appendingPathComponent(
            "shared.ts"
        )
        let canonicalURL = HLSDestinationIdentity.canonicalURL(
            for: destinationURL
        )
        let existingLease = try #require(
            try HLSCrossProcessDestinationLock.acquire(
                destinationURL: canonicalURL
            )
        )

        let event = await terminalEvent(
            from: HLSDownloader(session: session).download(
                sourceURL: playlistURL,
                destinationURL: destinationURL
            )
        )
        await existingLease.release()
        let reacquiredLease = try #require(
            try HLSCrossProcessDestinationLock.acquire(
                destinationURL: canonicalURL
            )
        )
        await reacquiredLease.release()

        #expect(
            {
                if case .failed(.destinationInUse) = event {
                    return true
                }
                return false
            }()
        )
        #expect(
            !HLSURLProtocol.capturedRequests().contains {
                $0.url == playlistURL
            }
        )
        let lockFileNames = try FileManager.default.contentsOfDirectory(
            atPath:
                directoryURL.appendingPathComponent(
                    ".innonetwork-hls-locks"
                ).path
        )
        #expect(lockFileNames.count == 1)
        #expect(
            lockFileNames.allSatisfy {
                !$0.contains(destinationURL.lastPathComponent)
            }
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: destinationURL.path
            )
        )
    }

    @Test("non-file destinations fail before network transfer")
    func nonFileDestinationIsRejected() async throws {
        let playlistURL = try #require(
            URL(string: "https://media.example/playlist.m3u8")
        )
        let destinationURL = try #require(
            URL(string: "https://files.example/output.ts")
        )
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }

        let terminalEvent = await terminalEvent(
            from: HLSDownloader(session: session).download(
                sourceURL: playlistURL,
                destinationURL: destinationURL
            )
        )

        #expect(
            {
                if case .failed(.invalidDestination) = terminalEvent {
                    return true
                }
                return false
            }())
        #expect(
            !HLSURLProtocol.capturedRequests().contains {
                $0.url == playlistURL
            }
        )
    }

    @Test("media limits are enforced before final-file commit")
    func mediaResourceLimitIsEnforced() async throws {
        let playlistURL = try #require(
            URL(string: "https://media.example/playlist.m3u8")
        )
        let segmentURL = try #require(
            URL(string: "https://media.example/segment.ts")
        )
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    """
                    #EXTM3U
                    #EXTINF:1,
                    segment.ts
                    #EXT-X-ENDLIST

                    """.utf8
                ),
                headers: [:]
            ),
            for: playlistURL
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data("12345".utf8),
                headers: ["Content-Length": "5"]
            ),
            for: segmentURL
        )
        let client = HLSHTTPClient(
            session: session,
            requestContext: .init(),
            requestAdapter: { $0 }
        )
        let downloader = HLSDownloader(
            client: client,
            configuration: .advanced(
                storage: HLSStoragePack(
                    maximumMediaResourceBytes: 4,
                    diskCapacityPolicy: .disabled
                ),
                transfer: HLSTransferPack(
                    maximumConcurrentResourceTransfers: 1,
                    retryPolicy: nil
                )
            )
        )
        let directoryURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let destinationURL = directoryURL.appendingPathComponent(
            "bounded.ts"
        )

        let terminalEvent = await terminalEvent(
            from: downloader.download(
                sourceURL: playlistURL,
                destinationURL: destinationURL
            )
        )

        let isExpectedFailure: Bool
        if case .failed(.mediaResourceTooLarge(limit: 4)) =
            terminalEvent
        {
            isExpectedFailure = true
        } else {
            isExpectedFailure = false
        }
        #expect(
            isExpectedFailure,
            "Unexpected terminal event: \(String(reflecting: terminalEvent))"
        )
        #expect(!FileManager.default.fileExists(atPath: destinationURL.path))
    }

    @Test("URLSession cancellation emits cancelled")
    func urlSessionCancellationIsClassified() async throws {
        let playlistURL = try #require(
            URL(string: "https://media.example/playlist.m3u8")
        )
        let segmentURL = try #require(
            URL(string: "https://media.example/segment.ts")
        )
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    """
                    #EXTM3U
                    #EXTINF:1,
                    segment.ts
                    #EXT-X-ENDLIST

                    """.utf8
                ),
                headers: [:]
            ),
            for: playlistURL
        )
        HLSURLProtocol.register(
            .unfinished(
                statusCode: 200,
                data: Data(),
                headers: [:]
            ),
            for: segmentURL
        )
        let directoryURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let destinationURL = directoryURL.appendingPathComponent(
            "cancelled.ts"
        )
        let (requestStream, requestContinuation) =
            AsyncStream<URL>.makeStream()
        HLSURLProtocol.setStartLoadingHandler { url in
            requestContinuation.yield(url)
        }
        let consumerTask = Task {
            for await event in HLSDownloader(session: session).download(
                sourceURL: playlistURL,
                destinationURL: destinationURL
            ) {
                if case .cancelled = event {
                    return true
                }
            }
            return false
        }
        var requestIterator = requestStream.makeAsyncIterator()
        while let requestedURL = await requestIterator.next() {
            if requestedURL == segmentURL {
                break
            }
        }
        session.invalidateAndCancel()
        let sawCancelledEvent = await consumerTask.value

        #expect(sawCancelledEvent)
        #expect(!FileManager.default.fileExists(atPath: destinationURL.path))
    }

    @Test("downloadReceipt preserves caller task cancellation")
    func downloadReceiptPreservesTaskCancellation() async throws {
        let playlistURL = try #require(
            URL(string: "https://media.example/playlist.m3u8")
        )
        let segmentURL = try #require(
            URL(string: "https://media.example/segment.ts")
        )
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        registerMediaPlaylist(
            at: playlistURL,
            resourceNames: ["segment.ts"]
        )
        HLSURLProtocol.register(
            .unfinished(
                statusCode: 200,
                data: Data("partial".utf8),
                headers: [:]
            ),
            for: segmentURL
        )
        let directoryURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let destinationURL = directoryURL.appendingPathComponent(
            "task-cancelled.ts"
        )
        let (requestStream, requestContinuation) =
            AsyncStream<URL>.makeStream()
        HLSURLProtocol.setStartLoadingHandler { url in
            requestContinuation.yield(url)
        }
        let task = Task {
            try await HLSDownloader(
                session: session,
                configuration: .advanced(
                    storage: HLSStoragePack(
                        diskCapacityPolicy: .disabled
                    )
                )
            ).downloadReceipt(
                sourceURL: playlistURL,
                destinationURL: destinationURL
            )
        }
        var requestIterator = requestStream.makeAsyncIterator()
        while let requestedURL = await requestIterator.next() {
            if requestedURL == segmentURL {
                break
            }
        }

        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(!FileManager.default.fileExists(atPath: destinationURL.path))
    }

    @Test("request adapter applies to playlist and media requests")
    func requestAdapterAppliesToEveryRequest() async throws {
        let playlistURL = try #require(
            URL(string: "https://media.example/playlist.m3u8")
        )
        let segmentURL = try #require(
            URL(string: "https://media.example/segment.ts")
        )
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    """
                    #EXTM3U
                    #EXTINF:1,
                    segment.ts
                    #EXT-X-ENDLIST

                    """.utf8
                ),
                headers: [:]
            ),
            for: playlistURL
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data("secured".utf8),
                headers: [:]
            ),
            for: segmentURL
        )
        let directoryURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let destinationURL = directoryURL.appendingPathComponent(
            "secured.ts"
        )
        let downloader = HLSDownloader(
            session: session,
            requestAdapter: { request in
                var request = request
                request.setValue(
                    "Bearer test-token",
                    forHTTPHeaderField: "Authorization"
                )
                return request
            }
        )

        _ = await terminalEvent(
            from: downloader.download(
                sourceURL: playlistURL,
                destinationURL: destinationURL
            )
        )

        let authorizationHeaders = HLSURLProtocol.capturedRequests()
            .map {
                $0.value(
                    forHTTPHeaderField: "Authorization"
                )
            }
        #expect(
            authorizationHeaders
                == ["Bearer test-token", "Bearer test-token"]
        )
    }

    @Test("disk capacity is checked before the playlist request")
    func insufficientDiskCapacityFailsBeforeNetworkTransfer() async throws {
        let playlistURL = try #require(
            URL(string: "https://media.example/playlist.m3u8")
        )
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        let client = HLSHTTPClient(
            session: session,
            requestContext: .init(),
            requestAdapter: { $0 }
        )
        let downloader = HLSDownloader(
            client: client,
            configuration: .advanced(
                storage: HLSStoragePack(
                    diskCapacityPolicy: .required(
                        minimumAvailableCapacity: 100
                    )
                ),
                transfer: HLSTransferPack(retryPolicy: nil)
            ),
            diskCapacityChecker: HLSDiskCapacityChecker(
                capacityProvider: { _ in 99 }
            )
        )
        let directoryURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let destinationURL = directoryURL.appendingPathComponent(
            "capacity.ts"
        )

        let event = await terminalEvent(
            from: downloader.download(
                sourceURL: playlistURL,
                destinationURL: destinationURL
            )
        )

        #expect(
            {
                if case .failed(
                    .insufficientDiskCapacity(
                        required: 100,
                        available: 99
                    )
                ) = event {
                    return true
                }
                return false
            }()
        )
        #expect(
            !HLSURLProtocol.capturedRequests().contains {
                $0.url == playlistURL
            }
        )
        #expect(!FileManager.default.fileExists(atPath: destinationURL.path))
    }

    @Test("disk capacity is rechecked before media bytes are persisted")
    func diskCapacityIsRecheckedDuringTransfer() async throws {
        let playlistURL = try #require(
            URL(string: "https://media.example/playlist.m3u8")
        )
        let segmentURL = try #require(
            URL(string: "https://media.example/segment.ts")
        )
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        registerMediaPlaylist(
            at: playlistURL,
            resourceNames: ["segment.ts"]
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data("12345".utf8),
                headers: ["Content-Length": "5"]
            ),
            for: segmentURL
        )
        let capacities = OSAllocatedUnfairLock<[Int64]>(
            initialState: [1_000, 1_000, 10]
        )
        let client = HLSHTTPClient(
            session: session,
            requestContext: .init(),
            requestAdapter: { $0 }
        )
        let downloader = HLSDownloader(
            client: client,
            configuration: .advanced(
                storage: HLSStoragePack(
                    diskCapacityPolicy: .required(
                        minimumAvailableCapacity: 10
                    ),
                    resumePolicy: .disabled
                ),
                transfer: HLSTransferPack(
                    maximumConcurrentResourceTransfers: 1,
                    retryPolicy: nil
                )
            ),
            diskCapacityChecker: HLSDiskCapacityChecker { _ in
                capacities.withLock { values in
                    if values.count > 1 {
                        return values.removeFirst()
                    }
                    return values[0]
                }
            }
        )
        let directoryURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let destinationURL = directoryURL.appendingPathComponent(
            "dynamic-capacity.ts"
        )

        let event = await terminalEvent(
            from: downloader.download(
                sourceURL: playlistURL,
                destinationURL: destinationURL
            )
        )

        guard
            case .failed(
                .insufficientDiskCapacity(
                    required: 15,
                    available: 10
                )
            ) = event
        else {
            Issue.record("Expected a dynamic disk-capacity failure.")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: destinationURL.path))
    }

    @Test("automatic resume skips resources at durable assembly boundaries")
    func automaticResumeSkipsCompletedResources() async throws {
        let playlistURL = try #require(
            URL(string: "https://media.example/playlist.m3u8")
        )
        let firstURL = try #require(
            URL(string: "https://media.example/first.ts")
        )
        let secondURL = try #require(
            URL(string: "https://media.example/second.ts")
        )
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        registerMediaPlaylist(
            at: playlistURL,
            resourceNames: ["first.ts", "second.ts"]
        )
        registerMediaPlaylist(
            at: playlistURL,
            resourceNames: ["first.ts", "second.ts"]
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data("FIRST".utf8),
                headers: ["Content-Length": "5"]
            ),
            for: firstURL
        )
        HLSURLProtocol.register(
            .failingResponse(
                statusCode: 200,
                data: Data("PART".utf8),
                headers: ["Content-Length": "6"],
                errorCode: .cancelled
            ),
            for: secondURL
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data("SECOND".utf8),
                headers: ["Content-Length": "6"]
            ),
            for: secondURL
        )
        let directoryURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let destinationURL = directoryURL.appendingPathComponent(
            "resumed.ts"
        )
        let resumeDirectoryURL = directoryURL.appendingPathComponent(
            ".resumed.ts.hls-resume",
            isDirectory: true
        )
        let configuration = HLSDownloadConfiguration.advanced(
            storage: HLSStoragePack(
                diskCapacityPolicy: .disabled,
                resumePolicy: .automatic
            ),
            transfer: HLSTransferPack(
                maximumConcurrentResourceTransfers: 1,
                retryPolicy: nil
            )
        )
        let firstDownloader = HLSDownloader(
            session: session,
            configuration: configuration
        )

        await #expect(throws: CancellationError.self) {
            try await firstDownloader.downloadFile(
                sourceURL: playlistURL,
                destinationURL: destinationURL
            )
        }
        #expect(
            FileManager.default.fileExists(
                atPath: resumeDirectoryURL.path
            )
        )

        let receipt = try await HLSDownloader(
            session: session,
            configuration: configuration
        ).downloadReceipt(
            sourceURL: playlistURL,
            destinationURL: destinationURL
        )

        #expect(receipt.resumedResourceTransferCount == 1)
        #expect(
            try Data(contentsOf: receipt.destinationURL)
                == Data("FIRSTSECOND".utf8)
        )
        let requests = HLSURLProtocol.capturedRequests()
        #expect(requests.filter { $0.url == firstURL }.count == 1)
        #expect(requests.filter { $0.url == secondURL }.count == 2)
        #expect(
            !FileManager.default.fileExists(
                atPath: resumeDirectoryURL.path
            )
        )
    }

    @Test("automatic resume restarts when playlist content changes")
    func automaticResumeRestartsAfterPlaylistContentChange() async throws {
        let playlistURL = try #require(
            URL(string: "https://media.example/playlist.m3u8")
        )
        let firstURL = try #require(
            URL(string: "https://media.example/first.ts")
        )
        let secondURL = try #require(
            URL(string: "https://media.example/second.ts")
        )
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        registerMediaPlaylist(
            at: playlistURL,
            resourceNames: ["first.ts", "second.ts"],
            comment: "version one"
        )
        registerMediaPlaylist(
            at: playlistURL,
            resourceNames: ["first.ts", "second.ts"],
            comment: "version two"
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data("OLD".utf8),
                headers: ["Content-Length": "3"]
            ),
            for: firstURL
        )
        HLSURLProtocol.register(
            .failingResponse(
                statusCode: 200,
                data: Data("PART".utf8),
                headers: ["Content-Length": "6"],
                errorCode: .cancelled
            ),
            for: secondURL
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data("NEW".utf8),
                headers: ["Content-Length": "3"]
            ),
            for: firstURL
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data("SECOND".utf8),
                headers: ["Content-Length": "6"]
            ),
            for: secondURL
        )
        let directoryURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let destinationURL = directoryURL.appendingPathComponent(
            "content-change.ts"
        )
        let configuration = resumableSerialConfiguration()

        await #expect(throws: CancellationError.self) {
            try await HLSDownloader(
                session: session,
                configuration: configuration
            ).downloadFile(
                sourceURL: playlistURL,
                destinationURL: destinationURL
            )
        }

        let receipt = try await HLSDownloader(
            session: session,
            configuration: configuration
        ).downloadReceipt(
            sourceURL: playlistURL,
            destinationURL: destinationURL
        )

        #expect(receipt.resumedResourceTransferCount == 0)
        #expect(
            try Data(contentsOf: receipt.destinationURL)
                == Data("NEWSECOND".utf8)
        )
        let requests = HLSURLProtocol.capturedRequests()
        #expect(requests.filter { $0.url == firstURL }.count == 2)
    }

    @Test("automatic resume restarts when a playlist validator changes")
    func automaticResumeRestartsAfterValidatorChange() async throws {
        let playlistURL = try #require(
            URL(string: "https://media.example/playlist.m3u8")
        )
        let firstURL = try #require(
            URL(string: "https://media.example/first.ts")
        )
        let secondURL = try #require(
            URL(string: "https://media.example/second.ts")
        )
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        registerMediaPlaylist(
            at: playlistURL,
            resourceNames: ["first.ts", "second.ts"],
            headers: ["ETag": "\"version-one\""]
        )
        registerMediaPlaylist(
            at: playlistURL,
            resourceNames: ["first.ts", "second.ts"],
            headers: ["ETag": "\"version-two\""]
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data("OLD".utf8),
                headers: ["Content-Length": "3"]
            ),
            for: firstURL
        )
        HLSURLProtocol.register(
            .failingResponse(
                statusCode: 200,
                data: Data("PART".utf8),
                headers: ["Content-Length": "6"],
                errorCode: .cancelled
            ),
            for: secondURL
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data("NEW".utf8),
                headers: ["Content-Length": "3"]
            ),
            for: firstURL
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data("SECOND".utf8),
                headers: ["Content-Length": "6"]
            ),
            for: secondURL
        )
        let directoryURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let destinationURL = directoryURL.appendingPathComponent(
            "validator-change.ts"
        )
        let configuration = resumableSerialConfiguration()

        await #expect(throws: CancellationError.self) {
            try await HLSDownloader(
                session: session,
                configuration: configuration
            ).downloadFile(
                sourceURL: playlistURL,
                destinationURL: destinationURL
            )
        }

        let receipt = try await HLSDownloader(
            session: session,
            configuration: configuration
        ).downloadReceipt(
            sourceURL: playlistURL,
            destinationURL: destinationURL
        )

        #expect(receipt.resumedResourceTransferCount == 0)
        #expect(
            try Data(contentsOf: receipt.destinationURL)
                == Data("NEWSECOND".utf8)
        )
        let requests = HLSURLProtocol.capturedRequests()
        #expect(requests.filter { $0.url == firstURL }.count == 2)
    }

    @Test("terminal mid-body failure rolls retained progress back")
    func terminalMidBodyFailureRollsProgressBack() async throws {
        let playlistURL = try #require(
            URL(string: "https://media.example/playlist.m3u8")
        )
        let segmentURL = try #require(
            URL(string: "https://media.example/segment.ts")
        )
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        registerMediaPlaylist(
            at: playlistURL,
            resourceNames: ["segment.ts"]
        )
        HLSURLProtocol.register(
            .failingResponse(
                statusCode: 200,
                data: Data("PART".utf8),
                headers: ["Content-Length": "8"],
                errorCode: .networkConnectionLost
            ),
            for: segmentURL
        )
        let directoryURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let destinationURL = directoryURL.appendingPathComponent(
            "progress-rollback.ts"
        )
        var progressEvents: [HLSDownloadProgress] = []
        var failure: HLSDownloadError?

        for await event in HLSDownloader(
            session: session,
            configuration: .advanced(
                storage: HLSStoragePack(
                    diskCapacityPolicy: .disabled,
                    resumePolicy: .disabled
                ),
                transfer: HLSTransferPack(
                    maximumConcurrentResourceTransfers: 1,
                    retryPolicy: nil
                )
            )
        ).download(
            sourceURL: playlistURL,
            destinationURL: destinationURL
        ) {
            switch event {
            case .progress(let progress):
                progressEvents.append(progress)
            case .failed(let error):
                failure = error
            case .completed, .cancelled:
                break
            }
        }

        #expect(failure != nil)
        #expect(progressEvents.last?.totalBytesWritten == 0)
    }

    @Test("the total byte budget spans every media resource")
    func totalDownloadLimitSpansResources() async throws {
        let playlistURL = try #require(
            URL(string: "https://media.example/playlist.m3u8")
        )
        let firstURL = try #require(
            URL(string: "https://media.example/first.ts")
        )
        let secondURL = try #require(
            URL(string: "https://media.example/second.ts")
        )
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        registerMediaPlaylist(
            at: playlistURL,
            resourceNames: ["first.ts", "second.ts"]
        )
        for url in [firstURL, secondURL] {
            HLSURLProtocol.register(
                .success(
                    statusCode: 200,
                    data: Data("123".utf8),
                    headers: ["Content-Length": "3"]
                ),
                for: url
            )
        }
        let directoryURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let destinationURL = directoryURL.appendingPathComponent(
            "total-limit.ts"
        )
        let configuration = HLSDownloadConfiguration.advanced(
            storage: HLSStoragePack(
                maximumMediaResourceBytes: 4,
                maximumTotalDownloadBytes: 5,
                diskCapacityPolicy: .disabled
            ),
            transfer: HLSTransferPack(
                maximumConcurrentResourceTransfers: 1,
                retryPolicy: nil
            )
        )

        let event = await terminalEvent(
            from: HLSDownloader(
                session: session,
                configuration: configuration
            ).download(
                sourceURL: playlistURL,
                destinationURL: destinationURL
            )
        )

        #expect(
            {
                if case .failed(
                    .totalDownloadTooLarge(limit: 5)
                ) = event {
                    return true
                }
                return false
            }()
        )
        #expect(!FileManager.default.fileExists(atPath: destinationURL.path))
    }

    @Test("transient media status failures use the core retry policy")
    func transientMediaStatusIsRetried() async throws {
        let playlistURL = try #require(
            URL(string: "https://media.example/playlist.m3u8")
        )
        let segmentURL = try #require(
            URL(string: "https://media.example/segment.ts")
        )
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        registerMediaPlaylist(
            at: playlistURL,
            resourceNames: ["segment.ts"]
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 503,
                data: Data(),
                headers: [:]
            ),
            for: segmentURL
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data("retried".utf8),
                headers: ["Content-Length": "7"]
            ),
            for: segmentURL
        )
        let directoryURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let destinationURL = directoryURL.appendingPathComponent(
            "retried.ts"
        )
        let configuration = retryTestConfiguration(maxRetries: 1)

        let event = await terminalEvent(
            from: HLSDownloader(
                session: session,
                configuration: configuration
            ).download(
                sourceURL: playlistURL,
                destinationURL: destinationURL
            )
        )

        guard case .completed = event else {
            Issue.record("Expected retry to recover the media resource.")
            return
        }
        #expect(
            try Data(contentsOf: destinationURL)
                == Data("retried".utf8)
        )
        #expect(
            HLSURLProtocol.capturedRequests()
                .filter { $0.url == segmentURL }
                .count == 2
        )
    }

    @Test("media retry publishes through request-context observers")
    func mediaRetryPublishesObservabilityEvent() async throws {
        let playlistURL = try #require(
            URL(string: "https://media.example/playlist.m3u8")
        )
        let segmentURL = try #require(
            URL(string: "https://media.example/segment.ts")
        )
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        registerMediaPlaylist(
            at: playlistURL,
            resourceNames: ["segment.ts"]
        )
        HLSURLProtocol.register(
            .success(statusCode: 503, data: Data(), headers: [:]),
            for: segmentURL
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data("retried".utf8),
                headers: ["Content-Length": "7"]
            ),
            for: segmentURL
        )
        let recorder = HLSNetworkEventRecorder()
        let observer = HLSRecordingNetworkEventObserver(recorder: recorder)
        let hlsRequestRecorder = HLSRequestEventRecorder()
        let directoryURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let destinationURL = directoryURL.appendingPathComponent(
            "observed-retry.ts"
        )

        let event = await terminalEvent(
            from: HLSDownloader(
                session: session,
                configuration: retryTestConfiguration(maxRetries: 1),
                requestContext: NetworkRequestContext(
                    eventObservers: [observer]
                ),
                requestPolicy: HLSRequestPolicy(
                    eventObservers: [hlsRequestRecorder]
                )
            ).download(
                sourceURL: playlistURL,
                destinationURL: destinationURL
            )
        )
        guard case .completed = event else {
            Issue.record("Expected observed retry to recover.")
            return
        }

        let retryEvents = await waitForRetryEvents(
            recorder: recorder,
            minimumCount: 1
        )
        #expect(retryEvents.count == 1)
        #expect(retryEvents.first?.retryIndex == 0)
        let mediaContexts = await hlsRequestRecorder.startedContexts()
            .filter { $0.purpose == .mediaResource }
        #expect(mediaContexts.map(\.retryIndex) == [0, 1])
        #expect(mediaContexts.map(\.resourceIndex) == [0, 0])
        #expect(Set(mediaContexts.map(\.requestID)).count == 1)
    }

    @Test("mid-body transport failures retry the whole media resource")
    func midBodyTransportFailureRetriesResource() async throws {
        let playlistURL = try #require(
            URL(string: "https://media.example/playlist.m3u8")
        )
        let segmentURL = try #require(
            URL(string: "https://media.example/segment.ts")
        )
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        registerMediaPlaylist(
            at: playlistURL,
            resourceNames: ["segment.ts"]
        )
        HLSURLProtocol.register(
            .failingResponse(
                statusCode: 200,
                data: Data("partial".utf8),
                headers: ["Content-Length": "12"],
                errorCode: .networkConnectionLost
            ),
            for: segmentURL
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data("complete".utf8),
                headers: ["Content-Length": "8"]
            ),
            for: segmentURL
        )
        let directoryURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let destinationURL = directoryURL.appendingPathComponent(
            "body-retried.ts"
        )
        var progressEvents: [HLSDownloadProgress] = []

        for await event in HLSDownloader(
            session: session,
            configuration: retryTestConfiguration(maxRetries: 1)
        ).download(
            sourceURL: playlistURL,
            destinationURL: destinationURL
        ) {
            if case .progress(let progress) = event {
                progressEvents.append(progress)
            }
        }

        #expect(try Data(contentsOf: destinationURL) == Data("complete".utf8))
        #expect(
            HLSURLProtocol.capturedRequests()
                .filter { $0.url == segmentURL }
                .count == 2
        )
        let finalProgress = try #require(progressEvents.last)
        #expect(finalProgress.totalBytesWritten == 8)
        #expect(finalProgress.totalBytesExpectedToWrite == 8)
        #expect(finalProgress.percentCompleted == 100)
    }

    @Test("media retry exhaustion surfaces the final typed status error")
    func mediaRetryExhaustionSurfacesStatusError() async throws {
        let playlistURL = try #require(
            URL(string: "https://media.example/playlist.m3u8")
        )
        let segmentURL = try #require(
            URL(string: "https://media.example/segment.ts")
        )
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        registerMediaPlaylist(
            at: playlistURL,
            resourceNames: ["segment.ts"]
        )
        for _ in 0..<2 {
            HLSURLProtocol.register(
                .success(
                    statusCode: 503,
                    data: Data(),
                    headers: [:]
                ),
                for: segmentURL
            )
        }
        let directoryURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let destinationURL = directoryURL.appendingPathComponent(
            "retry-exhausted.ts"
        )

        let event = await terminalEvent(
            from: HLSDownloader(
                session: session,
                configuration: retryTestConfiguration(maxRetries: 1)
            ).download(
                sourceURL: playlistURL,
                destinationURL: destinationURL
            )
        )

        #expect(
            {
                if case .failed(
                    .invalidMediaResponseStatus(503)
                ) = event {
                    return true
                }
                return false
            }()
        )
        #expect(
            HLSURLProtocol.capturedRequests()
                .filter { $0.url == segmentURL }
                .count == 2
        )
    }

    @Test("progress reports downloaded and expected media bytes")
    func progressReportsMediaBytes() async throws {
        let playlistURL = try #require(
            URL(string: "https://media.example/playlist.m3u8")
        )
        let segmentURL = try #require(
            URL(string: "https://media.example/segment.ts")
        )
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        registerMediaPlaylist(
            at: playlistURL,
            resourceNames: ["segment.ts"]
        )
        HLSURLProtocol.register(
            .delayedSuccess(
                statusCode: 200,
                data: Data("12345".utf8),
                headers: ["Content-Length": "5"],
                delay: 0.02
            ),
            for: segmentURL
        )
        let directoryURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let destinationURL = directoryURL.appendingPathComponent(
            "progress.ts"
        )
        var progressEvents: [HLSDownloadProgress] = []

        for await event in HLSDownloader(
            session: session,
            configuration: .advanced(
                storage: HLSStoragePack(diskCapacityPolicy: .disabled),
                transfer: HLSTransferPack(
                    maximumConcurrentResourceTransfers: 1,
                    retryPolicy: nil
                )
            )
        ).download(
            sourceURL: playlistURL,
            destinationURL: destinationURL
        ) {
            if case .progress(let progress) = event {
                progressEvents.append(progress)
            }
        }

        #expect(
            progressEvents.contains {
                $0.bytesWritten == 5
                    && $0.totalBytesWritten == 5
            }
        )
        let finalProgress = try #require(progressEvents.last)
        #expect(finalProgress.totalBytesWritten == 5)
        #expect(finalProgress.totalBytesExpectedToWrite == 5)
        #expect(finalProgress.fractionCompleted == 1)
        #expect(finalProgress.percentCompleted == 100)
    }

    @Test("bounded prefetch preserves playlist assembly order")
    func boundedPrefetchPreservesAssemblyOrder() async throws {
        let playlistURL = try #require(
            URL(string: "https://media.example/playlist.m3u8")
        )
        let resourceURLs = try ["first.ts", "second.ts", "third.ts"].map {
            try #require(
                URL(string: "https://media.example/\($0)")
            )
        }
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        registerMediaPlaylist(
            at: playlistURL,
            resourceNames: ["first.ts", "second.ts", "third.ts"]
        )
        HLSURLProtocol.register(
            .delayedSuccess(
                statusCode: 200,
                data: Data("FIRST".utf8),
                headers: ["Content-Length": "5"],
                delay: 0.08
            ),
            for: resourceURLs[0]
        )
        HLSURLProtocol.register(
            .delayedSuccess(
                statusCode: 200,
                data: Data("SECOND".utf8),
                headers: ["Content-Length": "6"],
                delay: 0.01
            ),
            for: resourceURLs[1]
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data("THIRD".utf8),
                headers: ["Content-Length": "5"]
            ),
            for: resourceURLs[2]
        )
        let directoryURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let destinationURL = directoryURL.appendingPathComponent(
            "ordered.ts"
        )

        let event = await terminalEvent(
            from: HLSDownloader(
                session: session,
                configuration: .advanced(
                    storage: HLSStoragePack(
                        diskCapacityPolicy: .disabled
                    ),
                    transfer: HLSTransferPack(
                        maximumConcurrentResourceTransfers: 2,
                        retryPolicy: nil
                    )
                )
            ).download(
                sourceURL: playlistURL,
                destinationURL: destinationURL
            )
        )

        guard case .completed = event else {
            Issue.record("Expected bounded parallel download to complete.")
            return
        }
        #expect(
            try Data(contentsOf: destinationURL)
                == Data("FIRSTSECONDTHIRD".utf8)
        )
        #expect(HLSURLProtocol.maximumActiveRequestCount() == 2)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HLSURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    #if canImport(AVFoundation)
    private func assertReadableVideoAsset(
        _ asset: AVURLAsset
    ) async throws {
        #expect(try await asset.load(.isPlayable))
        let videoTracks = try await asset.loadTracks(
            withMediaType: .video
        )
        let videoTrack = try #require(videoTracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: nil
        )
        #expect(reader.canAdd(output))
        reader.add(output)
        #expect(reader.startReading())
        #expect(output.copyNextSampleBuffer() != nil)
    }
    #endif

    private func makeTemporaryDirectory() throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "InnoNetworkHLSTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        return directoryURL
    }

    private func registerMediaPlaylist(
        at playlistURL: URL,
        resourceNames: [String],
        headers: [String: String] = [:],
        comment: String? = nil
    ) {
        let resources = resourceNames.map {
            "#EXTINF:1,\n\($0)"
        }.joined(separator: "\n")
        let commentLine = comment.map { "# \($0)\n" } ?? ""
        let playlist =
            "#EXTM3U\n\(commentLine)\(resources)\n#EXT-X-ENDLIST\n"
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(playlist.utf8),
                headers: headers
            ),
            for: playlistURL
        )
    }

    private func resumableSerialConfiguration()
        -> HLSDownloadConfiguration
    {
        HLSDownloadConfiguration.advanced(
            storage: HLSStoragePack(
                diskCapacityPolicy: .disabled,
                resumePolicy: .automatic
            ),
            transfer: HLSTransferPack(
                maximumConcurrentResourceTransfers: 1,
                retryPolicy: nil
            )
        )
    }

    private func retryTestConfiguration(
        maxRetries: Int
    ) -> HLSDownloadConfiguration {
        .advanced(
            storage: HLSStoragePack(diskCapacityPolicy: .disabled),
            transfer: HLSTransferPack(
                maximumConcurrentResourceTransfers: 1,
                retryPolicy: ExponentialBackoffRetryPolicy(
                    maxRetries: maxRetries,
                    retryDelay: 0,
                    maxDelay: 0,
                    jitterRatio: 0
                )
            )
        )
    }

    private func terminalEvent(
        from stream: AsyncStream<HLSDownloadEvent>
    ) async -> HLSDownloadEvent? {
        for await event in stream {
            switch event {
            case .completed, .failed, .cancelled:
                return event
            case .progress:
                continue
            }
        }
        return nil
    }

    private func waitForRetryEvents(
        recorder: HLSNetworkEventRecorder,
        minimumCount: Int
    ) async -> [(requestID: UUID, retryIndex: Int)] {
        for _ in 0..<1_000 {
            let events = await recorder.retryEvents()
            if events.count >= minimumCount {
                return events
            }
            await Task.yield()
        }
        return await recorder.retryEvents()
    }
}

private actor HLSNetworkEventRecorder {
    private var events: [NetworkEvent] = []

    func record(_ event: NetworkEvent) {
        events.append(event)
    }

    func retryEvents() -> [(requestID: UUID, retryIndex: Int)] {
        events.compactMap { event in
            guard
                case .retryScheduled(
                    let requestID,
                    let retryIndex,
                    _,
                    _
                ) = event
            else {
                return nil
            }
            return (requestID, retryIndex)
        }
    }
}

private struct HLSRecordingNetworkEventObserver: NetworkEventObserving {
    let recorder: HLSNetworkEventRecorder

    func handle(_ event: NetworkEvent) async {
        await recorder.record(event)
    }
}
