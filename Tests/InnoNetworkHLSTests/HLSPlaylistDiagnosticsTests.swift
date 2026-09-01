import Foundation
import Testing

@testable import InnoNetworkHLS

@Suite("HLS playlist diagnostics")
struct HLSPlaylistDiagnosticsTests {
    @Test("clean VOD playlists are valid for both download paths")
    func cleanVODHasNoDiagnostics() throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/vod.m3u8")
        )

        let inspection = PlaylistResolver().inspect(
            """
            #EXTM3U
            #EXTINF:1,
            segment.ts
            #EXT-X-ENDLIST
            """,
            relativeTo: sourceURL
        )

        #expect(inspection.isValid)
        #expect(inspection.canDownloadAsSingleFile)
        #expect(inspection.canCreateOfflinePackage)
        #expect(inspection.diagnostics.isEmpty)
    }

    @Test("empty media playlists cannot enter download planning")
    func emptyMediaPlaylistBlocksBothDownloadPaths() throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/empty.m3u8")
        )

        let inspection = PlaylistResolver().inspect(
            """
            #EXTM3U
            #EXT-X-ENDLIST
            """,
            relativeTo: sourceURL
        )

        #expect(inspection.isValid)
        #expect(!inspection.canDownloadAsSingleFile)
        #expect(!inspection.canCreateOfflinePackage)
        #expect(
            inspection.diagnostics.filter {
                $0.code == .emptyMediaPlaylist
            }.count == 2
        )
    }

    @Test("syntax findings are structured and preserve one-based lines")
    func invalidSyntaxIsStructured() throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/master.m3u8")
        )

        let inspection = PlaylistResolver().inspect(
            """
            ordinary text
            #EXT-X-VERSION:7
            #EXT-X-VERSION:8
            #EXT-X-STREAM-INF:BANDWIDTH
            #EXTINF:1,
            segment.ts
            """,
            relativeTo: sourceURL
        )

        #expect(!inspection.isValid)
        #expect(!inspection.canDownloadAsSingleFile)
        #expect(!inspection.canCreateOfflinePackage)
        #expect(
            inspection.diagnostics.contains {
                $0.code == .missingHeader && $0.lineNumber == 1
            }
        )
        #expect(
            inspection.diagnostics.contains {
                $0.code == .duplicateTag && $0.lineNumber == 3
            }
        )
        #expect(
            inspection.diagnostics.contains {
                $0.code == .malformedAttributeList
                    && $0.lineNumber == 4
            }
        )
        #expect(
            inspection.diagnostics.contains {
                $0.code == .mixedPlaylistKinds && $0.lineNumber == 5
            }
        )
    }

    @Test("missing key method is reported at the declaration")
    func missingKeyMethodIsStructured() throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/vod.m3u8")
        )

        let inspection = PlaylistResolver().inspect(
            """
            #EXTM3U
            #EXT-X-KEY:URI="key.bin"
            #EXTINF:1,
            segment.ts
            #EXT-X-ENDLIST
            """,
            relativeTo: sourceURL
        )

        #expect(!inspection.isValid)
        #expect(
            inspection.diagnostics.contains {
                $0.code == .missingRequiredAttribute
                    && $0.lineNumber == 2
            }
        )
    }

    @Test("live encryption failures remain operation scoped")
    func liveEncryptionIsOperationScoped() throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/live.m3u8")
        )

        let inspection = PlaylistResolver().inspect(
            """
            #EXTM3U
            #EXT-X-KEY:METHOD=SAMPLE-AES,URI="key.bin"
            #EXTINF:1,
            segment.ts
            """,
            relativeTo: sourceURL
        )

        #expect(inspection.isValid)
        #expect(!inspection.canDownloadAsSingleFile)
        #expect(!inspection.canCreateOfflinePackage)
        #expect(
            inspection.diagnostics.filter {
                $0.code == .livePlaylistUnsupported
            }.count == 2
        )
        #expect(
            inspection.diagnostics.filter {
                $0.code == .encryptionUnsupported
                    && $0.lineNumber == 2
            }.count == 2
        )
        let codes = Set(inspection.diagnostics.map(\.code))
        #expect(codes.contains(.livePlaylistUnsupported))
        #expect(codes.contains(.encryptionUnsupported))
    }

    @Test("parallel key formats keep identity AES-128 downloadable")
    func parallelKeyFormatsKeepIdentityDownloadable() throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/vod.m3u8")
        )
        let inspection = PlaylistResolver().inspect(
            """
            #EXTM3U
            #EXT-X-KEY:METHOD=AES-128,URI="key.bin"
            #EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://asset",KEYFORMAT="com.apple.streamingkeydelivery"
            #EXTINF:1,
            segment.ts
            #EXT-X-ENDLIST
            """,
            relativeTo: sourceURL
        )

        #expect(inspection.isValid)
        #expect(inspection.canDownloadAsSingleFile)
        #expect(inspection.canCreateOfflinePackage)
        #expect(
            !inspection.diagnostics.contains {
                $0.code == .encryptionUnsupported
            }
        )
    }

    @Test("non-identity AES-128 remains operation scoped")
    func nonIdentityAES128IsOperationScoped() throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/vod.m3u8")
        )
        let inspection = PlaylistResolver().inspect(
            """
            #EXTM3U
            #EXT-X-KEY:METHOD=AES-128,URI="packaged-key.bin",KEYFORMAT="com.example.wrapped-key"
            #EXTINF:1,
            segment.ts
            #EXT-X-ENDLIST
            """,
            relativeTo: sourceURL
        )

        #expect(inspection.isValid)
        #expect(!inspection.canDownloadAsSingleFile)
        #expect(!inspection.canCreateOfflinePackage)
        #expect(
            inspection.diagnostics.filter {
                $0.code == .encryptionUnsupported
                    && $0.lineNumber == 2
            }.count == 2
        )
    }

    @Test("raw size limit applies before removed definitions are parsed")
    func rawSizeLimitCannotBeBypassedByDefinitions() throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/master.m3u8")
        )
        let oversizedValue = String(
            repeating: "x",
            count: 2 * 1_024 * 1_024
        )
        let playlist = """
            #EXTM3U
            #EXT-X-VERSION:8
            #EXT-X-DEFINE:NAME="unused",VALUE="\(oversizedValue)"
            #EXT-X-STREAM-INF:BANDWIDTH=1000
            video.m3u8
            """
        let resolver = PlaylistResolver()

        #expect(
            throws: HLSDownloadError.playlistTooLarge(
                limit: 2 * 1_024 * 1_024
            )
        ) {
            _ = try resolver.resolve(playlist, relativeTo: sourceURL)
        }
        let inspection = resolver.inspect(
            playlist,
            relativeTo: sourceURL
        )
        #expect(!inspection.isValid)
        #expect(
            inspection.diagnostics == [
                HLSPlaylistDiagnostic(
                    severity: .error,
                    scope: .playlist,
                    code: .playlistTooLarge,
                    lineNumber: nil
                )
            ]
        )
    }

    @Test("I-frame media reports scoped capability failures")
    func iFrameMediaReportsCapabilityScopes() throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/iframe.m3u8")
        )

        let inspection = PlaylistResolver().inspect(
            """
            #EXTM3U
            #EXT-X-VERSION:4
            #EXT-X-I-FRAMES-ONLY
            #EXTINF:1,
            iframe.ts
            #EXT-X-ENDLIST
            """,
            relativeTo: sourceURL
        )

        #expect(inspection.isValid)
        #expect(!inspection.canDownloadAsSingleFile)
        #expect(!inspection.canCreateOfflinePackage)
        #expect(
            inspection.diagnostics.contains {
                $0.scope == .singleFileDownload
                    && $0.code == .mediaFeatureUnsupported
                    && $0.lineNumber == 3
                    && $0.mediaFeature == .iFramesOnly
            }
        )
        #expect(
            inspection.diagnostics.contains {
                $0.scope == .offlinePackage
                    && $0.mediaFeature == .iFramesOnly
            }
        )
    }

    @Test("steering and trick-play authoring issues stay operation scoped")
    func multivariantCapabilityDiagnostics() throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/master.m3u8")
        )

        let inspection = PlaylistResolver().inspect(
            """
            #EXTM3U
            #EXT-X-CONTENT-STEERING:SERVER-URI="steering.json"
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="English",URI="audio.m3u8"
            #EXT-X-STREAM-INF:BANDWIDTH=1000,RESOLUTION=1280x720,AUDIO="audio"
            video.m3u8
            #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=200,RESOLUTION=1920x1080,URI="iframe.m3u8"
            """,
            relativeTo: sourceURL
        )

        #expect(inspection.isValid)
        #expect(!inspection.canDownloadAsSingleFile)
        #expect(!inspection.canCreateOfflinePackage)
        #expect(
            inspection.diagnostics.contains {
                $0.code == .separateAudioRendition
                    && $0.scope == .singleFileDownload
                    && $0.severity == .error
                    && $0.lineNumber == 4
            }
        )
        #expect(
            inspection.diagnostics.contains {
                $0.code == .missingStableVariantID
                    && $0.scope == .offlinePackage
                    && $0.severity == .error
                    && $0.lineNumber == 4
            }
        )
        #expect(
            inspection.diagnostics.contains {
                $0.code == .missingStableRenditionID
                    && $0.lineNumber == 3
            }
        )
        #expect(
            inspection.diagnostics.contains {
                $0.code == .iFrameResolutionMismatch
                    && $0.severity == .warning
                    && $0.lineNumber == 6
            }
        )
    }

    @Test("partial separate-audio support is advisory")
    func partialSeparateAudioIsWarning() throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/master.m3u8")
        )

        let inspection = PlaylistResolver().inspect(
            """
            #EXTM3U
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="English",URI="audio.m3u8"
            #EXT-X-STREAM-INF:BANDWIDTH=1000,AUDIO="audio"
            separate.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=2000
            in-band.m3u8
            """,
            relativeTo: sourceURL
        )

        #expect(inspection.isValid)
        #expect(inspection.canDownloadAsSingleFile)
        #expect(
            inspection.diagnostics.contains {
                $0.code == .separateAudioRendition
                    && $0.severity == .warning
            }
        )
    }

    @Test("optional I-frame steering identity remains advisory")
    func optionalIFrameIdentityIsWarning() throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/master.m3u8")
        )

        let inspection = PlaylistResolver().inspect(
            """
            #EXTM3U
            #EXT-X-CONTENT-STEERING:SERVER-URI="steering.json"
            #EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID="trick",NAME="Angle",URI="trick-angle.m3u8"
            #EXT-X-STREAM-INF:BANDWIDTH=1000,STABLE-VARIANT-ID="video.main"
            video.m3u8
            #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=100,VIDEO="trick",STABLE-VARIANT-ID="iframe.main",URI="iframe.m3u8"
            """,
            relativeTo: sourceURL
        )

        #expect(inspection.isValid)
        #expect(inspection.canCreateOfflinePackage)
        #expect(
            inspection.diagnostics.contains {
                $0.code == .missingStableRenditionID
                    && $0.severity == .warning
                    && $0.lineNumber == 3
            }
        )
    }

    @Test("Apple authoring guidance is explicit and advisory")
    func appleAuthoringGuidanceIsOptIn() throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/vod.m3u8")
        )
        let source = """
            #EXTM3U
            #EXTINF:1,
            segment.ts
            #EXT-X-ENDLIST
            """

        let ordinary = PlaylistResolver().inspect(
            source,
            relativeTo: sourceURL
        )
        let authoring = PlaylistResolver().inspect(
            source,
            relativeTo: sourceURL,
            using: .appleAuthoring
        )

        #expect(ordinary.diagnostics.isEmpty)
        #expect(authoring.canDownloadAsSingleFile)
        #expect(authoring.canCreateOfflinePackage)
        #expect(
            authoring.diagnostics.map(\.code)
                == [
                    .appleIndependentSegmentsMissing,
                    .appleTargetDurationMissing,
                ]
        )
        #expect(
            authoring.appleAuthoringDiagnostics
                == authoring.diagnostics
        )
        #expect(
            authoring.appleAuthoringDiagnostics.allSatisfy {
                $0.severity == .warning
            }
        )
    }

    @Test("Apple media guidance validates target duration")
    func appleMediaTargetDurationGuidance() throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/vod.m3u8")
        )

        let inspection = PlaylistResolver().inspect(
            """
            #EXTM3U
            #EXT-X-VERSION:7
            #EXT-X-INDEPENDENT-SEGMENTS
            #EXT-X-TARGETDURATION:4
            #EXTINF:4.6,
            segment.ts
            #EXT-X-ENDLIST
            """,
            relativeTo: sourceURL,
            using: .appleAuthoring
        )

        #expect(inspection.isValid)
        #expect(
            inspection.diagnostics == [
                HLSPlaylistDiagnostic(
                    severity: .warning,
                    scope: .appleAuthoring,
                    code: .appleSegmentExceedsTargetDuration,
                    lineNumber: 5
                )
            ]
        )
    }

    @Test("Apple multivariant guidance is line-addressable")
    func appleMultivariantGuidance() throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/master.m3u8")
        )

        let inspection = PlaylistResolver().inspect(
            """
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=2000
            high.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=1000,CODECS="avc1.64001f"
            low.m3u8
            """,
            relativeTo: sourceURL,
            using: .appleAuthoring
        )

        #expect(inspection.isValid)
        #expect(inspection.canDownloadAsSingleFile)
        #expect(
            inspection.diagnostics.contains {
                $0.code == .appleIndependentSegmentsMissing
                    && $0.lineNumber == nil
            }
        )
        #expect(
            inspection.diagnostics.contains {
                $0.code == .appleCodecsMissing
                    && $0.lineNumber == 2
            }
        )
        #expect(
            inspection.diagnostics.count {
                $0.code == .appleAverageBandwidthMissing
            } == 2
        )
        #expect(
            inspection.diagnostics.contains {
                $0.code == .appleResolutionMissing
                    && $0.lineNumber == 4
            }
        )
        #expect(
            inspection.diagnostics.contains {
                $0.code == .appleVariantOrder
                    && $0.lineNumber == 4
            }
        )
    }

    @Test("well-authored Apple-oriented playlists add no guidance")
    func appleAuthoringCleanPlaylist() throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/master.m3u8")
        )

        let inspection = PlaylistResolver().inspect(
            """
            #EXTM3U
            #EXT-X-INDEPENDENT-SEGMENTS
            #EXT-X-STREAM-INF:BANDWIDTH=1000,AVERAGE-BANDWIDTH=900,CODECS="avc1.64001f,mp4a.40.2",RESOLUTION=640x360,FRAME-RATE=30
            low.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=2000,AVERAGE-BANDWIDTH=1800,CODECS="avc1.640020,mp4a.40.2",RESOLUTION=1280x720,FRAME-RATE=30
            high.m3u8
            """,
            relativeTo: sourceURL,
            using: .appleAuthoring
        )

        #expect(inspection.isValid)
        #expect(inspection.diagnostics.isEmpty)
    }

    @Test("Apple steering and media-selection guidance is typed")
    func appleSteeringAndMediaSelectionGuidance() throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/master.m3u8")
        )
        let inspection = PlaylistResolver().inspect(
            """
            #EXTM3U
            #EXT-X-INDEPENDENT-SEGMENTS
            #EXT-X-CONTENT-STEERING:SERVER-URI="steering.json"
            #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",URI="subs.m3u8"
            #EXT-X-STREAM-INF:BANDWIDTH=1000,AVERAGE-BANDWIDTH=900,CODECS="hvc1.2.4.L153.b0",RESOLUTION=640x360,FRAME-RATE=30,VIDEO-RANGE=PQ,SCORE=5,SUBTITLES="subs"
            hdr.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=2000,AVERAGE-BANDWIDTH=1800,CODECS="hvc1.2.4.L153.b0",RESOLUTION=1280x720,FRAME-RATE=30,SUBTITLES="subs"
            mixed.m3u8
            """,
            relativeTo: sourceURL,
            using: .appleAuthoring
        )

        #expect(inspection.isValid)
        #expect(
            inspection.diagnostics.contains {
                $0.code == .appleContentSteeringPathwayMissing
                    && $0.lineNumber == 3
            }
        )
        #expect(
            inspection.diagnostics.count {
                $0.code == .appleStableVariantIDMissing
            } == 2
        )
        #expect(
            inspection.diagnostics.contains {
                $0.code == .appleStableRenditionIDMissing
                    && $0.lineNumber == 4
            }
        )
        #expect(
            inspection.diagnostics.contains {
                $0.code == .appleCaptionLanguageMissing
                    && $0.lineNumber == 4
            }
        )
        #expect(
            inspection.diagnostics.contains {
                $0.code == .appleScoreIncomplete
                    && $0.lineNumber == 7
            }
        )
        #expect(
            inspection.diagnostics.contains {
                $0.code == .appleVideoRangeMissing
                    && $0.lineNumber == 7
            }
        )
    }

    @Test("Apple diagnostics retain lines after variant filtering")
    func appleDiagnosticsRetainLinesAfterVariantFiltering() throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/master.m3u8")
        )
        let inspection = PlaylistResolver().inspect(
            """
            #EXTM3U
            #EXT-X-VERSION:12
            #EXT-X-DEFINE:NAME="path",VALUE="selected.m3u8"
            #EXT-X-INDEPENDENT-SEGMENTS
            #EXT-X-STREAM-INF:BANDWIDTH=500,REQ-VIDEO-LAYOUT="CH-FUTURE"
            ignored.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=1000,AVERAGE-BANDWIDTH=900,CODECS="avc1.64001f",RESOLUTION=640x360
            {$path}
            """,
            relativeTo: sourceURL,
            using: .appleAuthoring
        )

        #expect(inspection.isValid)
        #expect(inspection.playlist?.variants.count == 1)
        #expect(
            inspection.diagnostics.contains {
                $0.code == .appleFrameRateMissing
                    && $0.lineNumber == 7
            }
        )
    }

    @Test("Apple Low-Latency guidance checks timeline and hold-back")
    func appleLowLatencyGuidance() throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/live.m3u8")
        )
        let inspection = PlaylistResolver().inspect(
            """
            #EXTM3U
            #EXT-X-INDEPENDENT-SEGMENTS
            #EXT-X-TARGETDURATION:4
            #EXT-X-PART-INF:PART-TARGET=1
            #EXT-X-SERVER-CONTROL:PART-HOLD-BACK=2
            #EXT-X-PART:DURATION=1,URI="part.ts"
            #EXTINF:4,
            segment.ts
            """,
            relativeTo: sourceURL,
            using: .appleAuthoring
        )

        #expect(inspection.isValid)
        #expect(
            inspection.diagnostics.contains {
                $0.code == .appleLowLatencyProgramDateTimeMissing
                    && $0.lineNumber == 6
            }
        )
        #expect(
            inspection.diagnostics.contains {
                $0.code == .applePartialSegmentHoldBackTooShort
                    && $0.lineNumber == 5
            }
        )
    }

    @Test("declared target duration remains protocol-valid")
    func invalidTargetDurationIsRejectedBeforeGuidance() throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/vod.m3u8")
        )
        for declaration in [
            "#EXT-X-TARGETDURATION:0",
            "#EXT-X-TARGETDURATION:not-a-number",
            """
            #EXT-X-TARGETDURATION:4
            #EXT-X-TARGETDURATION:4
            """,
        ] {
            let inspection = PlaylistResolver().inspect(
                """
                #EXTM3U
                \(declaration)
                #EXTINF:1,
                segment.ts
                #EXT-X-ENDLIST
                """,
                relativeTo: sourceURL,
                using: .appleAuthoring
            )

            #expect(!inspection.isValid)
            #expect(
                inspection.diagnostics.contains {
                    $0.scope == .playlist
                        && $0.severity == .error
                }
            )
        }
    }
}
