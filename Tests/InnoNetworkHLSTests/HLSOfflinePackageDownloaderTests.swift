import Foundation
import Testing

@testable import InnoNetworkHLS

extension HLSDownloaderTests {
    @Test("offline packages remove playlist definitions and signed query values")
    func offlinePackageDoesNotPersistPlaylistVariables() async throws {
        let playlistURL = try #require(
            URL(
                string:
                    "https://media.example/vod.m3u8?token=signed-secret"
            )
        )
        let resourceURL = try #require(
            URL(
                string:
                    "https://media.example/video.ts?token=signed-secret"
            )
        )
        let session = makeOfflineSession()
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
                    #EXT-X-VERSION:11
                    #EXT-X-DEFINE:QUERYPARAM="token"
                    #EXTINF:1,
                    video.ts?token={$token}
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
                data: Data("VIDEO".utf8),
                headers: [:]
            ),
            for: resourceURL
        )
        let parentURL = try makeOfflineTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: parentURL)
        }
        let destinationURL = parentURL.appendingPathComponent(
            "variable.hlspkg",
            isDirectory: true
        )

        _ = try await HLSOfflinePackageDownloader(
            session: session,
            configuration: .advanced(
                storage: HLSOfflinePackageStoragePack(
                    diskCapacityPolicy: .disabled
                )
            )
        ).downloadPackage(
            sourceURL: playlistURL,
            destinationDirectoryURL: destinationURL
        )

        let relativePaths = try FileManager.default.subpathsOfDirectory(
            atPath: destinationURL.path
        )
        for relativePath in relativePaths {
            let fileURL = destinationURL.appendingPathComponent(relativePath)
            guard
                let contents = try? String(
                    contentsOf: fileURL,
                    encoding: .utf8
                )
            else {
                continue
            }
            #expect(!contents.contains("signed-secret"))
            #expect(!contents.contains("EXT-X-DEFINE"))
            #expect(!contents.contains("{$token}"))
        }
    }

    @Test("primary, audio, and subtitle playlists are localized atomically")
    func downloadsMultiRenditionPackage() async throws {
        let urls = try FixtureURLs()
        let session = makeOfflineSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        registerMasterAndMediaPlaylists(urls)
        HLSURLProtocol.register(
            .success(
                statusCode: 206,
                data: Data("VIDE".utf8),
                headers: [
                    "Content-Length": "4",
                    "Content-Range": "bytes 1-4/10",
                ]
            ),
            for: urls.videoResource
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data("AUDIO".utf8),
                headers: ["Content-Length": "5"]
            ),
            for: urls.audioResource
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data("WEBVTT\n".utf8),
                headers: ["Content-Length": "7"]
            ),
            for: urls.subtitleResource
        )
        let parentURL = try makeOfflineTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: parentURL)
        }
        let destinationURL = parentURL.appendingPathComponent(
            "episode.hlspkg",
            isDirectory: true
        )

        let receipt = try await HLSOfflinePackageDownloader(
            session: session,
            configuration: .advanced(
                storage: HLSOfflinePackageStoragePack(
                    diskCapacityPolicy: .disabled
                ),
                renditions: HLSOfflineRenditionPack(
                    audio: .all,
                    subtitles: .all
                ),
                transfer: HLSTransferPack(
                    maximumConcurrentResourceTransfers: 2,
                    retryPolicy: nil
                )
            )
        ).downloadPackage(
            sourceURL: urls.master,
            destinationDirectoryURL: destinationURL
        )

        #expect(receipt.directoryURL == destinationURL)
        #expect(receipt.entryPlaylistURL == destinationURL.appendingPathComponent("index.m3u8"))
        #expect(receipt.tracks.map(\.kind) == [.primary, .audio, .subtitles])
        #expect(receipt.tracks[1].associatedLanguage == "en-US")
        #expect(receipt.tracks[1].stableID == "audio.main")
        #expect(receipt.tracks[1].instreamID == "main.audio")
        #expect(receipt.tracks[1].channels == "2")
        #expect(receipt.tracks[1].audioBitDepth == 24)
        #expect(receipt.tracks[1].audioSampleRate == 48_000)
        #expect(receipt.selectedVariant?.hdcpLevel == .type1)
        #expect(
            receipt.selectedVariant?
                .allowedContentProtectionConfigurations.first?
                .labels == ["HW"]
        )
        #expect(
            receipt.selectedVariant?.requiredVideoLayouts.first?
                .channelLayout == .stereoscopic
        )
        #expect(
            receipt.tracks[2].characteristics
                == [
                    "public.accessibility.transcribes-spoken-dialog"
                ]
        )
        #expect(receipt.byteCount > 16)

        let master = try String(
            contentsOf: receipt.entryPlaylistURL,
            encoding: .utf8
        )
        #expect(master.contains("media/primary/index.m3u8"))
        #expect(master.contains("#EXT-X-VERSION:13"))
        #expect(master.contains("media/audio-000/index.m3u8"))
        #expect(master.contains("media/subtitles-000/index.m3u8"))
        #expect(master.contains(#"ASSOC-LANGUAGE="en-US""#))
        #expect(master.contains(#"STABLE-RENDITION-ID="audio.main""#))
        #expect(master.contains(#"INSTREAM-ID="main.audio""#))
        #expect(master.contains(#"CHANNELS="2""#))
        #expect(master.contains("BIT-DEPTH=24"))
        #expect(master.contains("SAMPLE-RATE=48000"))
        #expect(master.contains("SCORE=0.0000001"))
        #expect(!master.contains("SCORE=1e-07"))
        #expect(
            master.contains(
                #"SUPPLEMENTAL-CODECS="dvh1.08.07/db4h""#
            )
        )
        #expect(master.contains(#"STABLE-VARIANT-ID="variant.main""#))
        #expect(master.contains("HDCP-LEVEL=TYPE-1"))
        #expect(master.contains(#"ALLOWED-CPC="com.example.drm:HW""#))
        #expect(
            master.contains(
                #"REQ-VIDEO-LAYOUT="CH-STEREO/PROJ-HEQU""#
            )
        )
        #expect(!master.contains("https://"))

        let videoPlaylist = try localizedPlaylist(
            receipt.tracks[0],
            in: destinationURL
        )
        #expect(videoPlaylist.contains("resources/00000.bin"))
        #expect(!videoPlaylist.contains("#EXT-X-BYTERANGE"))
        #expect(!videoPlaylist.contains("video.bin"))
        let audioPlaylist = try localizedPlaylist(
            receipt.tracks[1],
            in: destinationURL
        )
        #expect(audioPlaylist.contains("resources/00000.aac"))
        let subtitlePlaylist = try localizedPlaylist(
            receipt.tracks[2],
            in: destinationURL
        )
        #expect(subtitlePlaylist.contains("resources/00000.vtt"))

        #expect(
            try Data(
                contentsOf:
                    destinationURL
                    .appendingPathComponent("media/primary/resources/00000.bin")
            ) == Data("VIDE".utf8)
        )
        #expect(
            try Data(
                contentsOf:
                    destinationURL
                    .appendingPathComponent("media/audio-000/resources/00000.aac")
            ) == Data("AUDIO".utf8)
        )
        let manifest = try String(
            contentsOf: destinationURL.appendingPathComponent(
                "manifest.json"
            ),
            encoding: .utf8
        )
        #expect(manifest.contains(#""schemaVersion" : 3"#))
        #expect(manifest.contains(#""sha256" :"#))
        #expect(manifest.contains(#""associatedLanguage" : "en-US""#))
        #expect(manifest.contains(#""stableID" : "audio.main""#))
        #expect(manifest.contains(#""instreamID" : "main.audio""#))
        #expect(manifest.contains(#""score" :"#))
        #expect(manifest.contains(#""hdcpLevel" : "TYPE-1""#))
        #expect(
            manifest.contains(
                #""allowedContentProtectionConfigurations" :"#
            )
        )
        #expect(manifest.contains(#""requiredVideoLayouts" :"#))
        #expect(!manifest.contains("https://"))
        #expect(
            !FileManager.default.fileExists(
                atPath:
                    destinationURL
                    .appendingPathComponent(".staging-0").path
            )
        )

        let reopened = try HLSOfflinePackageStore().open(
            at: destinationURL
        )
        #expect(reopened.directoryURL == receipt.directoryURL)
        #expect(reopened.entryPlaylistURL == receipt.entryPlaylistURL)
        #expect(reopened.tracks == receipt.tracks)
        #expect(reopened.byteCount == receipt.byteCount)
        #expect(
            reopened.selectedVariant?.stableID
                == receipt.selectedVariant?.stableID
        )
        #expect(
            reopened.selectedVariant?.hdcpLevel
                == receipt.selectedVariant?.hdcpLevel
        )
        #expect(
            reopened.selectedVariant?
                .allowedContentProtectionConfigurations
                == receipt.selectedVariant?
                .allowedContentProtectionConfigurations
        )
        #expect(
            reopened.selectedVariant?.requiredVideoLayouts
                == receipt.selectedVariant?.requiredVideoLayouts
        )
        try HLSOfflinePackageStore().validate(at: destinationURL)
    }

    @Test("prepare resolves selected rendition playlists but no media bytes")
    func prepareResolvesMetadataOnly() async throws {
        let urls = try FixtureURLs()
        let session = makeOfflineSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        registerMasterAndMediaPlaylists(urls)

        let preparation = try await HLSOfflinePackageDownloader(
            session: session,
            configuration: .advanced(
                storage: HLSOfflinePackageStoragePack(
                    diskCapacityPolicy: .disabled
                ),
                renditions: HLSOfflineRenditionPack(
                    audio: .preferredLanguages(["en-US"]),
                    subtitles: .all
                )
            )
        ).prepare(sourceURL: urls.master)

        #expect(preparation.selectedVariant?.url == urls.videoPlaylist)
        #expect(preparation.tracks.map(\.kind) == [.primary, .audio, .subtitles])
        #expect(preparation.tracks[1].language == "en")
        #expect(preparation.resourceTransferCount == 3)
        let requests = HLSURLProtocol.capturedRequests().compactMap(\.url)
        #expect(requests.contains(urls.master))
        #expect(requests.contains(urls.videoPlaylist))
        #expect(requests.contains(urls.audioPlaylist))
        #expect(requests.contains(urls.subtitlePlaylist))
        #expect(!requests.contains(urls.videoResource))
        #expect(!requests.contains(urls.audioResource))
        #expect(!requests.contains(urls.subtitleResource))
    }

    @Test("external video and I-frame trick-play playlists stay playable offline")
    func downloadsVideoAndIFrameTrickPlay() async throws {
        let baseURL = try #require(
            URL(string: "https://media.example/trick-play/")
        )
        let masterURL = baseURL.appendingPathComponent("master.m3u8")
        let primaryURL = baseURL.appendingPathComponent("primary.m3u8")
        let videoURL = baseURL.appendingPathComponent("dugout.m3u8")
        let iFrameURL = baseURL.appendingPathComponent("iframe.m3u8")
        let iFrameVideoURL = baseURL.appendingPathComponent(
            "dugout-iframe.m3u8"
        )
        let session = makeOfflineSession()
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
                    #EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID="angles",NAME="Dugout",DEFAULT=YES,AUTOSELECT=YES,STABLE-RENDITION-ID="video.dugout",URI="dugout.m3u8"
                    #EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID="iframe-angles",NAME="Dugout",DEFAULT=YES,AUTOSELECT=YES,STABLE-RENDITION-ID="iframe.dugout",URI="dugout-iframe.m3u8"
                    #EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=1280x720,VIDEO="angles",STABLE-VARIANT-ID="video.main"
                    primary.m3u8
                    #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=100000,RESOLUTION=1280x720,VIDEO="iframe-angles",STABLE-VARIANT-ID="iframe.main",URI="iframe.m3u8"
                    #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=300000,RESOLUTION=3840x2160,STABLE-VARIANT-ID="iframe.4k",URI="iframe-4k.m3u8"

                    """.utf8
                ),
                headers: [:]
            ),
            for: masterURL
        )
        let playlists = [
            (primaryURL, "primary.ts", false),
            (videoURL, "dugout.ts", false),
            (iFrameURL, "iframe.ts", true),
            (iFrameVideoURL, "dugout-iframe.ts", true),
        ]
        for (url, resourceName, isIFrame) in playlists {
            HLSURLProtocol.register(
                .success(
                    statusCode: 200,
                    data: Data(
                        """
                        #EXTM3U
                        #EXT-X-VERSION:4
                        \(isIFrame ? "#EXT-X-I-FRAMES-ONLY" : "")
                        #EXTINF:1,
                        \(resourceName)
                        #EXT-X-ENDLIST

                        """.utf8
                    ),
                    headers: [:]
                ),
                for: url
            )
            HLSURLProtocol.register(
                .success(
                    statusCode: 200,
                    data: Data(resourceName.utf8),
                    headers: [:]
                ),
                for: baseURL.appendingPathComponent(resourceName)
            )
        }
        let parentURL = try makeOfflineTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parentURL) }
        let destinationURL = parentURL.appendingPathComponent(
            "trick-play.hlspkg",
            isDirectory: true
        )
        let downloader = HLSOfflinePackageDownloader(
            session: session,
            configuration: .advanced(
                storage: HLSOfflinePackageStoragePack(
                    diskCapacityPolicy: .disabled
                ),
                variantSelectionPolicy: .maximumBandwidth(2_000_000),
                renditions: HLSOfflineRenditionPack(
                    video: .all,
                    includesIFrameTrickPlay: true
                ),
                transfer: HLSTransferPack(retryPolicy: nil)
            )
        )

        let preparation = try await downloader.prepare(
            sourceURL: masterURL
        )
        #expect(preparation.selectedIFrameVariant?.stableID == "iframe.main")
        #expect(
            preparation.tracks.map(\.kind)
                == [.primary, .video, .iFrames, .iFrameVideo]
        )
        let receipt = try await downloader.downloadPackage(
            sourceURL: masterURL,
            destinationDirectoryURL: destinationURL
        )

        #expect(receipt.selectedIFrameVariant?.stableID == "iframe.main")
        #expect(receipt.tracks.map(\.kind) == preparation.tracks.map(\.kind))
        let entry = try PlaylistResolver().resolve(
            String(
                contentsOf: receipt.entryPlaylistURL,
                encoding: .utf8
            ),
            relativeTo: receipt.entryPlaylistURL
        )
        #expect(entry.variants.first?.videoGroupID == "offline-video")
        #expect(
            entry.iFrameVariants.first?.videoGroupID
                == "offline-iframe-video"
        )
        #expect(entry.renditions.count == 2)
        let reopened = try HLSOfflinePackageStore().open(at: destinationURL)
        #expect(reopened.tracks == receipt.tracks)
        #expect(reopened.selectedIFrameVariant?.stableID == "iframe.main")
    }

    @Test("a resource failure leaves no visible partial package")
    func failureIsAtomic() async throws {
        let playlistURL = try #require(
            URL(string: "https://media.example/video.m3u8")
        )
        let resourceURL = try #require(
            URL(string: "https://media.example/video.ts")
        )
        let session = makeOfflineSession()
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
                    video.ts
                    #EXT-X-ENDLIST

                    """.utf8
                ),
                headers: [:]
            ),
            for: playlistURL
        )
        HLSURLProtocol.register(
            .success(statusCode: 503, data: Data(), headers: [:]),
            for: resourceURL
        )
        let parentURL = try makeOfflineTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: parentURL)
        }
        let destinationURL = parentURL.appendingPathComponent(
            "failed.hlspkg",
            isDirectory: true
        )
        let downloader = HLSOfflinePackageDownloader(
            session: session,
            configuration: .advanced(
                storage: HLSOfflinePackageStoragePack(
                    diskCapacityPolicy: .disabled
                ),
                transfer: HLSTransferPack(retryPolicy: nil)
            )
        )

        await #expect(
            throws: HLSDownloadError.invalidMediaResponseStatus(503)
        ) {
            try await downloader.downloadPackage(
                sourceURL: playlistURL,
                destinationDirectoryURL: destinationURL
            )
        }

        #expect(
            !FileManager.default.fileExists(
                atPath: destinationURL.path
            )
        )
        let siblings = try FileManager.default.contentsOfDirectory(
            atPath: parentURL.path
        )
        #expect(
            Set(siblings)
                == [
                    ".failed.hlspkg.hls-package-resume",
                    ".innonetwork-hls-locks",
                ]
        )
        let lockArtifacts =
            try FileManager.default.contentsOfDirectory(
                atPath:
                    parentURL.appendingPathComponent(
                        ".innonetwork-hls-locks"
                    ).path
            )
        #expect(lockArtifacts.count == 1)
    }

    @Test("offline package resume reuses durable resource files")
    func offlinePackageResumeReusesResources() async throws {
        let playlistURL = try #require(
            URL(string: "https://media.example/resume.m3u8")
        )
        let firstResourceURL = try #require(
            URL(string: "https://media.example/first.ts")
        )
        let secondResourceURL = try #require(
            URL(string: "https://media.example/second.ts")
        )
        let session = makeOfflineSession()
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
                    #EXT-X-VERSION:3
                    #EXTINF:1,
                    first.ts
                    #EXTINF:1,
                    second.ts
                    #EXT-X-ENDLIST

                    """.utf8
                ),
                headers: ["ETag": "stable-plan"]
            ),
            for: playlistURL
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data("FIRST".utf8),
                headers: ["Content-Length": "5"]
            ),
            for: firstResourceURL
        )
        HLSURLProtocol.register(
            .success(statusCode: 503, data: Data(), headers: [:]),
            for: secondResourceURL
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data("SECOND".utf8),
                headers: ["Content-Length": "6"]
            ),
            for: secondResourceURL
        )
        let parentURL = try makeOfflineTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parentURL) }
        let destinationURL = parentURL.appendingPathComponent(
            "resumed.hlspkg",
            isDirectory: true
        )
        let downloader = HLSOfflinePackageDownloader(
            session: session,
            configuration: .advanced(
                storage: HLSOfflinePackageStoragePack(
                    diskCapacityPolicy: .disabled
                ),
                transfer: HLSTransferPack(
                    maximumConcurrentResourceTransfers: 1,
                    retryPolicy: nil
                )
            )
        )

        await #expect(
            throws: HLSDownloadError.invalidMediaResponseStatus(503)
        ) {
            try await downloader.downloadPackage(
                sourceURL: playlistURL,
                destinationDirectoryURL: destinationURL
            )
        }

        let receipt = try await downloader.downloadPackage(
            sourceURL: playlistURL,
            destinationDirectoryURL: destinationURL
        )

        #expect(receipt.resumedResourceTransferCount == 1)
        #expect(
            HLSURLProtocol.capturedRequests().filter {
                $0.url == firstResourceURL
            }.count == 1
        )
        #expect(
            HLSURLProtocol.capturedRequests().filter {
                $0.url == secondResourceURL
            }.count == 2
        )
        #expect(
            try HLSOfflinePackageStore().open(at: destinationURL)
                .resumedResourceTransferCount == 1
        )
        #expect(
            !FileManager.default.fileExists(
                atPath:
                    parentURL.appendingPathComponent(
                        ".resumed.hlspkg.hls-package-resume"
                    ).path
            )
        )
    }

    @Test("offline package resume discards a changed playlist plan")
    func offlinePackageResumeDiscardsChangedPlan() async throws {
        let playlistURL = try #require(
            URL(string: "https://media.example/changed.m3u8")
        )
        let firstResourceURL = try #require(
            URL(string: "https://media.example/changed-first.ts")
        )
        let failingResourceURL = try #require(
            URL(string: "https://media.example/changed-old.ts")
        )
        let replacementResourceURL = try #require(
            URL(string: "https://media.example/changed-new.ts")
        )
        let session = makeOfflineSession()
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
                    changed-first.ts
                    #EXTINF:1,
                    changed-old.ts
                    #EXT-X-ENDLIST

                    """.utf8
                ),
                headers: ["ETag": "old"]
            ),
            for: playlistURL
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    """
                    #EXTM3U
                    #EXTINF:1,
                    changed-first.ts
                    #EXTINF:1,
                    changed-new.ts
                    #EXT-X-ENDLIST

                    """.utf8
                ),
                headers: ["ETag": "new"]
            ),
            for: playlistURL
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data("FIRST".utf8),
                headers: ["Content-Length": "5"]
            ),
            for: firstResourceURL
        )
        HLSURLProtocol.register(
            .success(statusCode: 503, data: Data(), headers: [:]),
            for: failingResourceURL
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data("NEW".utf8),
                headers: ["Content-Length": "3"]
            ),
            for: replacementResourceURL
        )
        let parentURL = try makeOfflineTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parentURL) }
        let destinationURL = parentURL.appendingPathComponent(
            "changed.hlspkg",
            isDirectory: true
        )
        let downloader = HLSOfflinePackageDownloader(
            session: session,
            configuration: .advanced(
                storage: HLSOfflinePackageStoragePack(
                    diskCapacityPolicy: .disabled
                ),
                transfer: HLSTransferPack(
                    maximumConcurrentResourceTransfers: 1,
                    retryPolicy: nil
                )
            )
        )

        await #expect(
            throws: HLSDownloadError.invalidMediaResponseStatus(503)
        ) {
            try await downloader.downloadPackage(
                sourceURL: playlistURL,
                destinationDirectoryURL: destinationURL
            )
        }
        let receipt = try await downloader.downloadPackage(
            sourceURL: playlistURL,
            destinationDirectoryURL: destinationURL
        )

        #expect(receipt.resumedResourceTransferCount == 0)
        #expect(
            HLSURLProtocol.capturedRequests().filter {
                $0.url == firstResourceURL
            }.count == 2
        )
    }

    @Test("unmodeled URI-bearing media tags are rejected")
    func rejectsUnmodeledRemoteReferences() {
        #expect(throws: HLSDownloadError.invalidPlaylist) {
            try HLSOfflineMediaPlaylistWriter.validate(
                contents: """
                    #EXTM3U
                    #EXT-X-PART:DURATION=0.5,URI="partial.m4s"
                    #EXT-X-ENDLIST
                    """
            )
        }
    }

    @Test("all-rendition selection is explicitly bounded")
    func allRenditionsAreBounded() async throws {
        let masterURL = try #require(
            URL(string: "https://media.example/master.m3u8")
        )
        let primaryURL = try #require(
            URL(string: "https://media.example/video.m3u8")
        )
        let session = makeOfflineSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        let audioLines = (0..<3).map { index in
            """
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Audio \(index)",URI="audio-\(index).m3u8"
            """
        }.joined(separator: "\n")
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    """
                    #EXTM3U
                    \(audioLines)
                    #EXT-X-STREAM-INF:BANDWIDTH=1000,AUDIO="audio"
                    video.m3u8

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
                    video.ts
                    #EXT-X-ENDLIST

                    """.utf8
                ),
                headers: [:]
            ),
            for: primaryURL
        )
        let downloader = HLSOfflinePackageDownloader(
            session: session,
            configuration: .advanced(
                storage: HLSOfflinePackageStoragePack(
                    diskCapacityPolicy: .disabled
                ),
                renditions: HLSOfflineRenditionPack(
                    audio: .all,
                    maximumRenditionsPerKind: 2
                )
            )
        )

        await #expect(
            throws: HLSDownloadError.offlineRenditionLimitExceeded(
                limit: 2
            )
        ) {
            try await downloader.prepare(sourceURL: masterURL)
        }
        #expect(
            HLSURLProtocol.capturedRequests().count == 1
        )
    }

    @Test("regular and I-frame video renditions share one fan-out limit")
    func videoRenditionsShareOneLimit() async throws {
        let masterURL = try #require(
            URL(string: "https://media.example/video-limit/master.m3u8")
        )
        let session = makeOfflineSession()
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
                    #EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID="regular",NAME="Regular 1",URI="regular-1.m3u8"
                    #EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID="regular",NAME="Regular 2",URI="regular-2.m3u8"
                    #EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID="trick",NAME="Trick 1",URI="trick-1.m3u8"
                    #EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID="trick",NAME="Trick 2",URI="trick-2.m3u8"
                    #EXT-X-STREAM-INF:BANDWIDTH=1000,VIDEO="regular"
                    primary.m3u8
                    #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=100,VIDEO="trick",URI="iframe.m3u8"

                    """.utf8
                ),
                headers: [:]
            ),
            for: masterURL
        )

        await #expect(
            throws: HLSDownloadError.offlineRenditionLimitExceeded(
                limit: 3
            )
        ) {
            try await HLSOfflinePackageDownloader(
                session: session,
                configuration: .advanced(
                    renditions: HLSOfflineRenditionPack(
                        video: .all,
                        includesIFrameTrickPlay: true,
                        maximumRenditionsPerKind: 3
                    )
                )
            ).prepare(sourceURL: masterURL)
        }
        #expect(HLSURLProtocol.capturedRequests().count == 1)
    }

    @Test("the committed local playlists round-trip through the parser")
    func packagePlaylistsRoundTrip() async throws {
        let playlistURL = try #require(
            URL(string: "https://media.example/vod.m3u8")
        )
        let initializationURL = try #require(
            URL(string: "https://media.example/init.mp4")
        )
        let segment0URL = try #require(
            URL(string: "https://media.example/segment-0.m4s")
        )
        let segment1URL = try #require(
            URL(string: "https://media.example/segment-1.m4s")
        )
        let session = makeOfflineSession()
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
        for (url, data) in try [
            (initializationURL, HLSMediaFixtures.fragmentedMP4Initialization()),
            (segment0URL, HLSMediaFixtures.fragmentedMP4Segment0()),
            (segment1URL, HLSMediaFixtures.fragmentedMP4Segment1()),
        ] {
            HLSURLProtocol.register(
                .success(
                    statusCode: 200,
                    data: data,
                    headers: [
                        "Content-Length": "\(data.count)"
                    ]
                ),
                for: url
            )
        }
        let parentURL = try makeOfflineTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: parentURL)
        }
        let receipt = try await HLSOfflinePackageDownloader(
            session: session,
            configuration: .advanced(
                storage: HLSOfflinePackageStoragePack(
                    diskCapacityPolicy: .disabled
                ),
                transfer: HLSTransferPack(retryPolicy: nil)
            )
        ).downloadPackage(
            sourceURL: playlistURL,
            destinationDirectoryURL:
                parentURL.appendingPathComponent(
                    "playable.hlspkg",
                    isDirectory: true
                )
        )

        let masterText = try String(
            contentsOf: receipt.entryPlaylistURL,
            encoding: .utf8
        )
        let master = try PlaylistResolver().resolve(
            masterText,
            relativeTo: receipt.entryPlaylistURL
        )
        #expect(master.kind == .multivariant)
        #expect(master.protocolVersion == 7)
        let primaryPlaylistURL =
            receipt.directoryURL.appendingPathComponent(
                receipt.tracks[0].relativePlaylistPath
            )
        #expect(master.variants.first?.url == primaryPlaylistURL)

        let primaryText = try String(
            contentsOf: primaryPlaylistURL,
            encoding: .utf8
        )
        let primary = try PlaylistResolver().resolve(
            primaryText,
            relativeTo: primaryPlaylistURL
        )
        #expect(primary.kind == .media)
        #expect(primary.media?.resources.count == 3)
        #expect(
            primary.media?.resources.allSatisfy {
                $0.url.isFileURL
                    && $0.url.path.hasPrefix(receipt.directoryURL.path)
            } == true
        )
    }

    @Test("offline package validation detects resource corruption")
    func offlinePackageValidationDetectsCorruption() throws {
        let parentURL = try makeOfflineTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parentURL) }
        let packageURL = try makeLocalOfflinePackage(in: parentURL)
        let resourceURL = packageURL.appendingPathComponent(
            "media/primary/resources/00000.ts"
        )
        try Data("CORRUPTED".utf8).write(to: resourceURL)

        #expect(throws: HLSDownloadError.invalidOfflinePackage) {
            try HLSOfflinePackageStore().validate(at: packageURL)
        }
    }

    @Test("offline package validation rejects path traversal")
    func offlinePackageValidationRejectsPathTraversal() throws {
        let parentURL = try makeOfflineTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parentURL) }
        let packageURL = try makeLocalOfflinePackage(in: parentURL)
        try mutateOfflineManifest(at: packageURL) { manifest in
            var tracks = try #require(manifest["tracks"] as? [[String: Any]])
            tracks[0]["playlistPath"] = "../outside.m3u8"
            manifest["tracks"] = tracks
        }

        #expect(throws: HLSDownloadError.invalidOfflinePackage) {
            try HLSOfflinePackageStore().open(at: packageURL)
        }
    }

    @Test("offline package validation rejects symbolic links")
    func offlinePackageValidationRejectsSymbolicLinks() throws {
        let parentURL = try makeOfflineTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parentURL) }
        let packageURL = try makeLocalOfflinePackage(in: parentURL)
        let resourceURL = packageURL.appendingPathComponent(
            "media/primary/resources/00000.ts"
        )
        let outsideURL = parentURL.appendingPathComponent("outside.ts")
        try Data("VIDEO".utf8).write(to: outsideURL)
        try FileManager.default.removeItem(at: resourceURL)
        try FileManager.default.createSymbolicLink(
            at: resourceURL,
            withDestinationURL: outsideURL
        )

        #expect(throws: HLSDownloadError.invalidOfflinePackage) {
            try HLSOfflinePackageStore().validate(at: packageURL)
        }
    }

    @Test("legacy schema 2 packages reopen with structural validation")
    func legacyOfflinePackageReopens() throws {
        let parentURL = try makeOfflineTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parentURL) }
        let packageURL = try makeLocalOfflinePackage(in: parentURL)
        try mutateOfflineManifest(at: packageURL) { manifest in
            manifest["schemaVersion"] = 2
            manifest.removeValue(forKey: "files")
        }

        let receipt = try HLSOfflinePackageStore().open(at: packageURL)

        #expect(receipt.tracks.map(\.kind) == [.primary])
        #expect(receipt.entryPlaylistURL.lastPathComponent == "index.m3u8")
    }

    @Test("unknown offline package schemas retain their version")
    func unknownOfflinePackageSchemaIsTyped() throws {
        let parentURL = try makeOfflineTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parentURL) }
        let packageURL = try makeLocalOfflinePackage(in: parentURL)
        try mutateOfflineManifest(at: packageURL) { manifest in
            manifest["schemaVersion"] = 999
        }

        #expect(
            throws:
                HLSDownloadError.unsupportedOfflinePackageSchema(
                    version: 999
                )
        ) {
            try HLSOfflinePackageStore().open(at: packageURL)
        }
    }

    @Test("offline package validation rejects unreferenced files")
    func offlinePackageValidationRejectsUnreferencedFiles() throws {
        let parentURL = try makeOfflineTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parentURL) }
        let packageURL = try makeLocalOfflinePackage(in: parentURL)
        try Data("ORPHAN".utf8).write(
            to: packageURL.appendingPathComponent("orphan.bin")
        )

        #expect(throws: HLSDownloadError.invalidOfflinePackage) {
            try HLSOfflinePackageStore().validate(at: packageURL)
        }
    }

    private func registerMasterAndMediaPlaylists(
        _ urls: FixtureURLs
    ) {
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    """
                    #EXTM3U
                    #EXT-X-VERSION:13
                    #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="English",LANGUAGE="en",ASSOC-LANGUAGE="en-US",STABLE-RENDITION-ID="audio.main",INSTREAM-ID="main.audio",DEFAULT=YES,AUTOSELECT=YES,CHARACTERISTICS="public.accessibility.describes-video",CHANNELS="2",BIT-DEPTH=24,SAMPLE-RATE=48000,URI="audio.m3u8"
                    #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="한국어",LANGUAGE="ko",STABLE-RENDITION-ID="subs.ko",DEFAULT=YES,AUTOSELECT=YES,CHARACTERISTICS="public.accessibility.transcribes-spoken-dialog",URI="subs.m3u8"
                    #EXT-X-STREAM-INF:BANDWIDTH=2000000,SCORE=0.0000001,RESOLUTION=1920x1080,CODECS="hvc1.2.4.L153.b0,mp4a.40.2",SUPPLEMENTAL-CODECS="dvh1.08.07/db4h",HDCP-LEVEL=TYPE-1,ALLOWED-CPC="com.example.drm:HW",REQ-VIDEO-LAYOUT="CH-STEREO/PROJ-HEQU",AUDIO="audio",SUBTITLES="subs",STABLE-VARIANT-ID="variant.main"
                    video.m3u8

                    """.utf8
                ),
                headers: [:]
            ),
            for: urls.master
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    """
                    #EXTM3U
                    #EXT-X-BYTERANGE:4@1
                    #EXTINF:1,
                    video.bin
                    #EXT-X-ENDLIST

                    """.utf8
                ),
                headers: [:]
            ),
            for: urls.videoPlaylist
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    """
                    #EXTM3U
                    #EXTINF:1,
                    audio.aac
                    #EXT-X-ENDLIST

                    """.utf8
                ),
                headers: [:]
            ),
            for: urls.audioPlaylist
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    """
                    #EXTM3U
                    #EXTINF:1,
                    subtitle.vtt
                    #EXT-X-ENDLIST

                    """.utf8
                ),
                headers: [:]
            ),
            for: urls.subtitlePlaylist
        )
    }

    private func makeLocalOfflinePackage(
        in parentURL: URL
    ) throws -> URL {
        let packageURL = parentURL.appendingPathComponent(
            "local.hlspkg",
            isDirectory: true
        )
        let primaryURL = packageURL.appendingPathComponent(
            "media/primary",
            isDirectory: true
        )
        let resourcesURL = primaryURL.appendingPathComponent(
            "resources",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: resourcesURL,
            withIntermediateDirectories: true
        )
        try Data("VIDEO".utf8).write(
            to: resourcesURL.appendingPathComponent("00000.ts")
        )
        try Data(
            """
            #EXTM3U
            #EXT-X-VERSION:3
            #EXTINF:1,
            resources/00000.ts
            #EXT-X-ENDLIST

            """.utf8
        ).write(to: primaryURL.appendingPathComponent("index.m3u8"))
        try Data(
            """
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=1000
            media/primary/index.m3u8

            """.utf8
        ).write(to: packageURL.appendingPathComponent("index.m3u8"))

        let track = HLSOfflinePackageTrack(
            kind: .primary,
            name: nil,
            language: nil,
            isDefault: false,
            isAutoselect: false,
            isForced: false,
            relativePlaylistPath: "media/primary/index.m3u8"
        )
        let records = try HLSOfflinePackageIntegrity.scan(
            directoryURL: packageURL,
            hashingFiles: true
        ).records
        let manifest = HLSOfflinePackageManifest(
            entryPlaylistPath: "index.m3u8",
            tracks: [track],
            selectedVariant: nil,
            files: records
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(
            to: packageURL.appendingPathComponent("manifest.json")
        )
        return packageURL
    }

    private func mutateOfflineManifest(
        at packageURL: URL,
        _ mutation: (inout [String: Any]) throws -> Void
    ) throws {
        let manifestURL = packageURL.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        var manifest = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        try mutation(&manifest)
        try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: manifestURL)
    }

    private func makeOfflineSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HLSURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeOfflineTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "InnoNetworkHLSOfflineTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    private func localizedPlaylist(
        _ track: HLSOfflinePackageTrack,
        in directoryURL: URL
    ) throws -> String {
        try String(
            contentsOf:
                directoryURL.appendingPathComponent(
                    track.relativePlaylistPath
                ),
            encoding: .utf8
        )
    }

    private struct FixtureURLs {
        let master: URL
        let videoPlaylist: URL
        let audioPlaylist: URL
        let subtitlePlaylist: URL
        let videoResource: URL
        let audioResource: URL
        let subtitleResource: URL

        init() throws {
            self.master = try #require(
                URL(string: "https://media.example/master.m3u8")
            )
            self.videoPlaylist = try #require(
                URL(string: "https://media.example/video.m3u8")
            )
            self.audioPlaylist = try #require(
                URL(string: "https://media.example/audio.m3u8")
            )
            self.subtitlePlaylist = try #require(
                URL(string: "https://media.example/subs.m3u8")
            )
            self.videoResource = try #require(
                URL(string: "https://media.example/video.bin")
            )
            self.audioResource = try #require(
                URL(string: "https://media.example/audio.aac")
            )
            self.subtitleResource = try #require(
                URL(string: "https://media.example/subtitle.vtt")
            )
        }
    }
}
