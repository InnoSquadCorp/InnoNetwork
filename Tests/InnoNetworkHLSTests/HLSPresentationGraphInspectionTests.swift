import Foundation
import Testing

@testable import InnoNetworkHLS

@Suite("HLS presentation graph inspection", .serialized)
struct HLSPresentationGraphInspectionTests {
    @Test("a conformant graph is fetched with bounded concurrency")
    func conformantGraphUsesBoundedConcurrency() async throws {
        let masterURL = try url("https://media.example/master.m3u8")
        let firstVideoURL = try url("https://media.example/video-a.m3u8")
        let secondVideoURL = try url("https://media.example/video-b.m3u8")
        let audioURL = try url("https://media.example/audio.m3u8")
        let subtitleURL = try url("https://media.example/subtitles.m3u8")
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSPresentationTestURLProtocol.reset()
        }
        register(
            """
            #EXTM3U
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Stereo",URI="audio.m3u8"
            #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",LANGUAGE="en",URI="subtitles.m3u8"
            #EXT-X-STREAM-INF:BANDWIDTH=1000,AUDIO="audio",SUBTITLES="subs"
            video-a.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=2000,AUDIO="audio",SUBTITLES="subs"
            video-b.m3u8
            """,
            for: masterURL
        )
        let media = conformantMediaPlaylist()
        for mediaURL in [
            firstVideoURL,
            secondVideoURL,
            audioURL,
            subtitleURL,
        ] {
            register(media, for: mediaURL, delay: 0.03)
        }

        let inspection = try await PlaylistResolver(
            session: session
        ).inspectPresentation(
            from: masterURL,
            using: .advanced(
                limits: HLSPresentationInspectionLimitPack(
                    maximumConcurrentRequests: 2
                )
            )
        )

        #expect(inspection.isConformant)
        #expect(inspection.diagnostics.isEmpty)
        #expect(inspection.mediaPlaylists.count == 4)
        #expect(
            inspection.mediaPlaylists.map(\.roles)
                == [
                    [.variant],
                    [.variant],
                    [.audioRendition],
                    [.subtitleRendition],
                ]
        )
        #expect(
            HLSPresentationTestURLProtocol.maximumActiveRequestCount()
                == 2
        )
    }

    @Test("graph diagnostics classify cross-playlist mismatches")
    func graphDiagnosticsClassifyMismatches() async throws {
        let masterURL = try url("https://media.example/mismatch.m3u8")
        let firstURL = try url("https://media.example/first.m3u8")
        let secondURL = try url("https://media.example/second.m3u8")
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSPresentationTestURLProtocol.reset()
        }
        register(twoVariantMaster(), for: masterURL)
        register(conformantMediaPlaylist(), for: firstURL)
        register(
            """
            #EXTM3U
            #EXT-X-TARGETDURATION:5
            #EXT-X-PLAYLIST-TYPE:VOD
            #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=NO
            #EXT-X-PROGRAM-DATE-TIME:2026-01-01T00:00:01.000Z
            #EXT-X-DATERANGE:ID="event",START-DATE="2026-01-01T00:00:00.000Z",DURATION=8
            #EXTINF:3,
            first.ts
            #EXTINF:1,
            second.ts
            #EXT-X-ENDLIST
            """,
            for: secondURL
        )

        let inspection = try await PlaylistResolver(
            session: session
        ).inspectPresentation(from: masterURL)
        let codes = Set(inspection.diagnostics.map(\.code))

        #expect(!inspection.isConformant)
        #expect(codes.contains(.targetDurationMismatch))
        #expect(codes.contains(.serverControlMismatch))
        #expect(codes.contains(.dateRangeAttributeMismatch))
        #expect(codes.contains(.programDateTimeMappingMismatch))
    }

    @Test("playlist type declarations must be graph-consistent")
    func playlistTypeIsGraphConsistent() async throws {
        let masterURL = try url("https://media.example/types.m3u8")
        let firstURL = try url("https://media.example/first.m3u8")
        let secondURL = try url("https://media.example/second.m3u8")
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSPresentationTestURLProtocol.reset()
        }
        register(twoVariantMaster(), for: masterURL)
        register(conformantMediaPlaylist(), for: firstURL)
        register(
            conformantMediaPlaylist().replacingOccurrences(
                of: "#EXT-X-PLAYLIST-TYPE:VOD",
                with: "#EXT-X-PLAYLIST-TYPE:EVENT"
            ),
            for: secondURL
        )

        let inspection = try await PlaylistResolver(
            session: session
        ).inspectPresentation(from: masterURL)

        #expect(
            inspection.diagnostics.contains {
                $0.code == .playlistTypeMismatch
            }
        )
    }

    @Test("timeline diagnostics separate boundaries and discontinuities")
    func timelineDiagnosticsAreTyped() async throws {
        let masterURL = try url("https://media.example/timeline.m3u8")
        let firstURL = try url("https://media.example/first.m3u8")
        let secondURL = try url("https://media.example/second.m3u8")
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSPresentationTestURLProtocol.reset()
        }
        register(twoVariantMaster(), for: masterURL)
        register(conformantMediaPlaylist(), for: firstURL)
        register(
            conformantMediaPlaylist(
                discontinuitySequence: 1
            ),
            for: secondURL
        )

        let discontinuityInspection = try await PlaylistResolver(
            session: session
        ).inspectPresentation(from: masterURL)
        #expect(
            discontinuityInspection.diagnostics.contains {
                $0.code == .discontinuitySequenceMismatch
                    && $0.playlistIndex == 1
                    && $0.relatedPlaylistIndex == 0
            }
        )

        HLSPresentationTestURLProtocol.reset()
        register(twoVariantMaster(), for: masterURL)
        register(conformantMediaPlaylist(), for: firstURL)
        register(
            """
            #EXTM3U
            #EXT-X-TARGETDURATION:4
            #EXT-X-DISCONTINUITY-SEQUENCE:1
            #EXT-X-PLAYLIST-TYPE:VOD
            #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES
            #EXT-X-PROGRAM-DATE-TIME:2026-01-01T00:00:00.000Z
            #EXT-X-DATERANGE:ID="event",START-DATE="2026-01-01T00:00:00.000Z",DURATION=4
            #EXTINF:3,
            first.ts
            #EXT-X-DISCONTINUITY
            #EXTINF:1,
            second.ts
            #EXT-X-ENDLIST
            """,
            for: secondURL
        )

        let timelineInspection = try await PlaylistResolver(
            session: session
        ).inspectPresentation(from: masterURL)
        #expect(
            timelineInspection.diagnostics.contains {
                $0.code == .timelineAlignmentMismatch
            }
        )
    }

    @Test("program date time must be present across the graph")
    func programDateTimePresenceIsGraphWide() async throws {
        let masterURL = try url("https://media.example/dates.m3u8")
        let firstURL = try url("https://media.example/first.m3u8")
        let secondURL = try url("https://media.example/second.m3u8")
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSPresentationTestURLProtocol.reset()
        }
        register(twoVariantMaster(), for: masterURL)
        register(conformantMediaPlaylist(), for: firstURL)
        register(
            """
            #EXTM3U
            #EXT-X-TARGETDURATION:4
            #EXT-X-PLAYLIST-TYPE:VOD
            #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES
            #EXTINF:2,
            first.ts
            #EXT-X-DISCONTINUITY
            #EXTINF:2,
            second.ts
            #EXT-X-ENDLIST
            """,
            for: secondURL
        )

        let inspection = try await PlaylistResolver(
            session: session
        ).inspectPresentation(from: masterURL)

        #expect(
            inspection.diagnostics.contains {
                $0.code == .programDateTimeMissing
                    && $0.playlistIndex == 1
            }
        )
    }

    @Test("duplicate references are fetched once and retain every role")
    func duplicateReferencesAreCoalesced() async throws {
        let masterURL = try url("https://media.example/coalesced.m3u8")
        let sharedURL = try url("https://media.example/shared.m3u8")
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSPresentationTestURLProtocol.reset()
        }
        register(
            """
            #EXTM3U
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Shared",URI="shared.m3u8"
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="unused",NAME="Unused",URI="unused.m3u8"
            #EXT-X-STREAM-INF:BANDWIDTH=1000,AUDIO="audio"
            shared.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=2000,AUDIO="audio"
            shared.m3u8
            """,
            for: masterURL
        )
        register(conformantMediaPlaylist(), for: sharedURL)

        let inspection = try await PlaylistResolver(
            session: session
        ).inspectPresentation(
            from: masterURL,
            using: .advanced(
                limits: HLSPresentationInspectionLimitPack(
                    maximumPlaylistCount: 2
                )
            )
        )

        #expect(inspection.mediaPlaylists.count == 1)
        #expect(
            inspection.mediaPlaylists[0].roles
                == [.variant, .audioRendition]
        )
        #expect(
            HLSPresentationTestURLProtocol.capturedRequests().compactMap(\.url)
                == [masterURL, sharedURL]
        )
    }

    @Test("I-frame playlists participate in graph-wide metadata rules")
    func iFramePlaylistMetadataIsInspected() async throws {
        let masterURL = try url("https://media.example/iframe-master.m3u8")
        let videoURL = try url("https://media.example/video.m3u8")
        let iFrameURL = try url("https://media.example/iframe.m3u8")
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSPresentationTestURLProtocol.reset()
        }
        register(
            """
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=1000
            video.m3u8
            #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=500,URI="iframe.m3u8"
            """,
            for: masterURL
        )
        register(conformantMediaPlaylist(), for: videoURL)
        register(
            """
            #EXTM3U
            #EXT-X-TARGETDURATION:8
            #EXT-X-PLAYLIST-TYPE:VOD
            #EXT-X-I-FRAMES-ONLY
            #EXTINF:4,
            iframe.ts
            #EXT-X-ENDLIST
            """,
            for: iFrameURL
        )

        let inspection = try await PlaylistResolver(
            session: session
        ).inspectPresentation(from: masterURL)

        #expect(
            !inspection.diagnostics.contains {
                $0.code == .targetDurationMismatch
                    && $0.playlistIndex == 1
            }
        )
        #expect(
            inspection.diagnostics.contains {
                $0.code == .serverControlMismatch
                    && $0.playlistIndex == 1
            }
        )
    }

    @Test("graph limits fail before unbounded child loading")
    func graphLimitsAreTyped() async throws {
        let masterURL = try url("https://media.example/limited.m3u8")
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSPresentationTestURLProtocol.reset()
        }
        register(twoVariantMaster(), for: masterURL)
        let resolver = PlaylistResolver(session: session)

        await #expect(
            throws:
                HLSPresentationInspectionError
                .playlistLimitExceeded(limit: 2)
        ) {
            try await resolver.inspectPresentation(
                from: masterURL,
                using: .advanced(
                    limits: HLSPresentationInspectionLimitPack(
                        maximumPlaylistCount: 2
                    )
                )
            )
        }
        #expect(
            HLSPresentationTestURLProtocol.capturedRequests().compactMap(\.url)
                == [masterURL]
        )
    }

    @Test("aggregate playlist bytes remain bounded")
    func aggregatePlaylistBytesAreBounded() async throws {
        let masterURL = try url("https://media.example/bytes.m3u8")
        let firstURL = try url("https://media.example/first.m3u8")
        let secondURL = try url("https://media.example/second.m3u8")
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSPresentationTestURLProtocol.reset()
        }
        register(twoVariantMaster(), for: masterURL)
        let padding = String(repeating: "x", count: 100)
        let minimalMedia = """
            #EXTM3U
            #\(padding)
            #EXT-X-TARGETDURATION:4
            #EXTINF:4,
            segment.ts
            #EXT-X-ENDLIST
            """
        register(minimalMedia, for: firstURL)
        register(minimalMedia, for: secondURL)

        await #expect(
            throws:
                HLSPresentationInspectionError
                .totalPlaylistBytesExceeded(limit: 256)
        ) {
            try await PlaylistResolver(
                session: session
            ).inspectPresentation(
                from: masterURL,
                using: .advanced(
                    limits: HLSPresentationInspectionLimitPack(
                        maximumPlaylistCount: 3,
                        maximumPlaylistBytes: 256,
                        maximumTotalPlaylistBytes: 256
                    )
                )
            )
        }
    }

    @Test("multivariant variables are imported by every child")
    func graphImportsMultivariantVariables() async throws {
        let masterURL = try url("https://media.example/variables.m3u8")
        let childURL = try url("https://media.example/child.m3u8")
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSPresentationTestURLProtocol.reset()
        }
        register(
            """
            #EXTM3U
            #EXT-X-VERSION:8
            #EXT-X-DEFINE:NAME="token",VALUE="segment"
            #EXT-X-STREAM-INF:BANDWIDTH=1000
            child.m3u8
            """,
            for: masterURL
        )
        register(
            """
            #EXTM3U
            #EXT-X-VERSION:8
            #EXT-X-DEFINE:IMPORT="token"
            #EXT-X-TARGETDURATION:4
            #EXT-X-PLAYLIST-TYPE:VOD
            #EXTINF:4,
            {$token}.ts
            #EXT-X-ENDLIST
            """,
            for: childURL
        )

        let inspection = try await PlaylistResolver(
            session: session
        ).inspectPresentation(from: masterURL)

        #expect(inspection.isConformant)
        #expect(inspection.mediaPlaylists.count == 1)
    }

    @Test("a direct media entry produces one bounded graph node")
    func directMediaEntryIsInspectable() async throws {
        let mediaURL = try url("https://media.example/direct.m3u8")
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSPresentationTestURLProtocol.reset()
        }
        register(conformantMediaPlaylist(), for: mediaURL)

        let inspection = try await PlaylistResolver(
            session: session
        ).inspectPresentation(from: mediaURL)

        #expect(inspection.entryPlaylist.kind == .media)
        #expect(inspection.mediaPlaylists.count == 1)
        #expect(inspection.mediaPlaylists[0].roles == [.entry])
        #expect(inspection.isConformant)
    }

    private func conformantMediaPlaylist(
        discontinuitySequence: Int = 0
    ) -> String {
        """
        #EXTM3U
        #EXT-X-TARGETDURATION:4
        #EXT-X-DISCONTINUITY-SEQUENCE:\(discontinuitySequence)
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES
        #EXT-X-PROGRAM-DATE-TIME:2026-01-01T00:00:00.000Z
        #EXT-X-DATERANGE:ID="event",START-DATE="2026-01-01T00:00:00.000Z",DURATION=4
        #EXTINF:2,
        first.ts
        #EXT-X-DISCONTINUITY
        #EXTINF:2,
        second.ts
        #EXT-X-ENDLIST
        """
    }

    private func twoVariantMaster() -> String {
        """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=1000
        first.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2000
        second.m3u8
        """
    }

    private func register(
        _ playlist: String,
        for url: URL,
        delay: TimeInterval? = nil
    ) {
        HLSPresentationTestURLProtocol.register(
            Data(playlist.utf8),
            for: url,
            delay: delay ?? 0
        )
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HLSPresentationTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func url(_ value: String) throws -> URL {
        try #require(URL(string: value))
    }
}
