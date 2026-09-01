import Foundation
import Testing

@testable import InnoNetworkHLS

@Suite("Low-Latency HLS metadata")
struct HLSLowLatencyTests {
    @Test("LL-HLS delivery metadata is typed and value bounded")
    func parsesLowLatencyMetadata() throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/live/main.m3u8")
        )
        let source = """
            #EXTM3U
            #EXT-X-VERSION:10
            #EXT-X-TARGETDURATION:4
            #EXT-X-PART-INF:PART-TARGET=1
            #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,CAN-SKIP-UNTIL=24,CAN-SKIP-DATERANGES=YES,HOLD-BACK=12,PART-HOLD-BACK=2
            #EXT-X-MEDIA-SEQUENCE:10
            #EXT-X-PART:DURATION=1,URI="parts.ts",INDEPENDENT=YES,BYTERANGE="100@0"
            #EXT-X-PART:DURATION=1,URI="parts.ts",BYTERANGE="100"
            #EXTINF:4,
            segment10.ts
            #EXT-X-PRELOAD-HINT:TYPE=PART,URI="parts.ts",BYTERANGE-START=200,BYTERANGE-LENGTH=100
            #EXT-X-RENDITION-REPORT:URI="../alternate.m3u8",LAST-MSN=10,LAST-PART=1
            #EXT-X-SKIP:SKIPPED-SEGMENTS=2,RECENTLY-REMOVED-DATERANGES="one	two"
            """

        let playlist = try PlaylistResolver().resolve(
            source,
            relativeTo: sourceURL
        )
        let lowLatency = try #require(playlist.lowLatency)

        #expect(lowLatency.serverControl?.canBlockReload == true)
        #expect(lowLatency.serverControl?.canSkipUntil == 24)
        #expect(lowLatency.serverControl?.canSkipDateRanges == true)
        #expect(lowLatency.serverControl?.holdBack == 12)
        #expect(
            lowLatency.serverControl?.partialSegmentHoldBack == 2
        )
        #expect(lowLatency.partialSegmentTargetDuration == 1)
        #expect(lowLatency.partialSegments.count == 2)
        #expect(lowLatency.partialSegments[0].segmentIndex == 0)
        #expect(lowLatency.partialSegments[0].isIndependent)
        #expect(lowLatency.partialSegments[0].byteRange?.offset == 0)
        #expect(lowLatency.partialSegments[1].byteRange?.offset == 100)
        #expect(
            lowLatency.preloadHints.first?.url.absoluteString
                == "https://media.example/live/parts.ts"
        )
        #expect(lowLatency.preloadHints.first?.byteRangeStart == 200)
        #expect(lowLatency.preloadHints.first?.byteRangeLength == 100)
        #expect(
            lowLatency.renditionReports.first?.url.absoluteString
                == "https://media.example/alternate.m3u8"
        )
        #expect(
            lowLatency.renditionReports.first?
                .lastMediaSequenceNumber == 10
        )
        #expect(
            lowLatency.renditionReports.first?
                .lastPartialSegmentIndex == 1
        )
        #expect(lowLatency.deltaUpdate?.skippedSegmentCount == 2)
        #expect(
            lowLatency.deltaUpdate?.recentlyRemovedDateRangeIDs
                == ["one", "two"]
        )
    }

    @Test("LL-HLS resources produce operation-scoped diagnostics")
    func lowLatencyDiagnosticsAreOperationScoped() throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/live/main.m3u8")
        )

        let inspection = PlaylistResolver().inspect(
            """
            #EXTM3U
            #EXT-X-VERSION:9
            #EXT-X-TARGETDURATION:4
            #EXT-X-PART-INF:PART-TARGET=1
            #EXT-X-SERVER-CONTROL:PART-HOLD-BACK=2
            #EXT-X-MAP:URI="init.mp4"
            #EXT-X-PART:DURATION=1,URI="part.m4s"
            #EXTINF:4,
            segment.m4s
            #EXT-X-PRELOAD-HINT:TYPE=PART,URI="next.m4s"
            #EXT-X-RENDITION-REPORT:URI="alternate.m3u8",LAST-MSN=1
            #EXT-X-SKIP:SKIPPED-SEGMENTS=1
            """,
            relativeTo: sourceURL
        )

        #expect(inspection.isValid)
        #expect(!inspection.canDownloadAsSingleFile)
        #expect(!inspection.canCreateOfflinePackage)
        for feature in [
            HLSUnsupportedMediaFeature.partialSegments,
            .deltaUpdate,
        ] {
            #expect(
                inspection.diagnostics.count {
                    $0.code == .mediaFeatureUnsupported
                        && $0.mediaFeature == feature
                } == 2
            )
        }
        for feature in [
            HLSUnsupportedMediaFeature.preloadHintResource,
            .renditionReportResource,
        ] {
            #expect(
                inspection.diagnostics.count {
                    $0.code == .mediaFeatureUnsupported
                        && $0.mediaFeature == feature
                        && $0.scope == .offlinePackage
                } == 1
            )
        }
        #expect(
            inspection.diagnostics.contains {
                $0.mediaFeature == .partialSegments
                    && $0.lineNumber == 7
            }
        )
    }

    @Test("non-delta LL-HLS metadata remains version 1 compatible")
    func nonDeltaLowLatencyMetadataDoesNotRequireVersion() throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/live/main.m3u8")
        )

        let playlist = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-TARGETDURATION:1
            #EXT-X-PART-INF:PART-TARGET=1
            #EXT-X-SERVER-CONTROL:PART-HOLD-BACK=2
            #EXT-X-PART:DURATION=0.5,URI="final-part.ts"
            #EXTINF:0.5,
            segment.ts
            #EXT-X-RENDITION-REPORT:URI="alternate.m3u8",LAST-PART=0
            #EXT-X-ENDLIST
            """,
            relativeTo: sourceURL
        )

        #expect(playlist.protocolVersion == nil)
        #expect(playlist.lowLatency?.partialSegments.count == 1)
        #expect(
            playlist.lowLatency?.renditionReports.first?
                .lastMediaSequenceNumber == nil
        )
    }

    @Test("only the first preload hint for one type is retained")
    func multipleSameTypePreloadHintsRetainFirst() throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/live/main.m3u8")
        )
        let firstHintURL = try #require(
            URL(string: "https://media.example/live/one.ts")
        )

        let playlist = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-TARGETDURATION:1
            #EXT-X-PART-INF:PART-TARGET=1
            #EXT-X-SERVER-CONTROL:PART-HOLD-BACK=2
            #EXT-X-PRELOAD-HINT:TYPE=PART,URI="one.ts"
            #EXT-X-PRELOAD-HINT:TYPE=PART,URI="two.ts"
            """,
            relativeTo: sourceURL
        )

        #expect(
            playlist.lowLatency?.preloadHints.map(\.url)
                == [firstHintURL]
        )
    }

    @Test("duplicate key hints are ignored before parsing their metadata")
    func duplicateKeyPreloadHintsIgnoreLaterMetadata() throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/live/main.m3u8")
        )

        let playlist = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-PRELOAD-HINT:TYPE=KEY,URI="first.key",METHOD=AES-128
            #EXT-X-PRELOAD-HINT:TYPE=KEY,URI="ignored.key"
            """,
            relativeTo: sourceURL
        )

        #expect(
            playlist.lowLatency?.preloadHints.map(\.url.absoluteString)
                == ["https://media.example/live/first.key"]
        )
    }

    @Test("decryption-key preload hints expose key metadata")
    func parsesEncryptionKeyPreloadHints() throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/live/main.m3u8")
        )

        let playlist = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-VERSION:5
            #EXT-X-PRELOAD-HINT:TYPE=KEY,URI="keys/next",BYTERANGE-START=16,BYTERANGE-LENGTH=32,METHOD=SAMPLE-AES,KEYFORMAT="com.apple.streamingkeydelivery",KEYFORMATVERSIONS="1/2",DATE-OF-FIRST-USE="2026-08-06T12:00:08Z"
            """,
            relativeTo: sourceURL
        )
        let hint = try #require(
            playlist.lowLatency?.preloadHints.first
        )
        let key = try #require(hint.encryptionKey)

        #expect(hint.type == .encryptionKey)
        #expect(
            hint.url.absoluteString
                == "https://media.example/live/keys/next"
        )
        #expect(hint.byteRangeStart == 16)
        #expect(hint.byteRangeLength == 32)
        #expect(key.method == "SAMPLE-AES")
        #expect(
            key.keyFormat
                == "com.apple.streamingkeydelivery"
        )
        #expect(key.keyFormatVersions == [1, 2])
        #expect(
            hint.estimatedFirstUseDate
                == ISO8601DateFormatter().date(
                    from: "2026-08-06T12:00:08Z"
                )
        )
    }

    @Test("preload ranges imply a zero start and retain first-use dates")
    func parsesImplicitPreloadRangeStart() throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/live/main.m3u8")
        )

        let playlist = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-PRELOAD-HINT:TYPE=MAP,URI="next.init",BYTERANGE-LENGTH=32,DATE-OF-FIRST-USE="2026-08-06T12:00:08Z"
            """,
            relativeTo: sourceURL
        )
        let hint = try #require(
            playlist.lowLatency?.preloadHints.first
        )

        #expect(hint.byteRangeStart == nil)
        #expect(hint.byteRangeLength == 32)
        #expect(hint.estimatedFirstUseDate != nil)
    }

    @Test("PART and MAP resources retain their presentation context")
    func retainsResourcePresentationContext() throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/live/main.m3u8")
        )

        let playlist = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-VERSION:10
            #EXT-X-TARGETDURATION:2
            #EXT-X-MEDIA-SEQUENCE:10
            #EXT-X-DISCONTINUITY-SEQUENCE:7
            #EXT-X-PART-INF:PART-TARGET=1
            #EXT-X-SERVER-CONTROL:PART-HOLD-BACK=2
            #EXT-X-MAP:URI="init.mp4"
            #EXT-X-PART:DURATION=1,URI="10.0.m4s",INDEPENDENT=YES
            #EXT-X-DISCONTINUITY
            #EXT-X-PART:DURATION=1,URI="11.0.m4s",INDEPENDENT=YES
            #EXT-X-PRELOAD-HINT:TYPE=MAP,URI="next-init.mp4",BYTERANGE-START=512
            #EXT-X-PRELOAD-HINT:TYPE=PART,URI="11.1.m4s"
            """,
            relativeTo: sourceURL
        )
        let lowLatency = try #require(playlist.lowLatency)
        let firstPart = try #require(
            lowLatency.partialSegments.first?.resourceContext
        )
        let secondPart = try #require(
            lowLatency.partialSegments.last?.resourceContext
        )
        let partHint = try #require(
            lowLatency.preloadHints.first(where: {
                $0.type == .partialSegment
            })?.resourceContext
        )

        #expect(firstPart.discontinuitySequence == 7)
        #expect(
            firstPart.initializationMap?.url.absoluteString
                == "https://media.example/live/init.mp4"
        )
        #expect(secondPart.discontinuitySequence == 8)
        #expect(
            partHint.initializationMap?.url.absoluteString
                == "https://media.example/live/next-init.mp4"
        )
        #expect(
            partHint.initializationMap?
                .openEndedByteRangeStart == 512
        )
    }

    @Test("LL-HLS contexts prefer identity AES-128 across key formats")
    func selectsIdentityEncryptionForResourceContexts() throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/live/main.m3u8")
        )
        let fairPlay =
            "#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"skd://asset\",KEYFORMAT=\"com.apple.streamingkeydelivery\""
        let identity =
            "#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\",IV=0x1"
        let keyURL = try #require(
            URL(string: "https://media.example/live/key.bin")
        )

        for declarations in [
            "\(fairPlay)\n\(identity)",
            "\(identity)\n\(fairPlay)",
        ] {
            let playlist = try PlaylistResolver().resolve(
                """
                #EXTM3U
                #EXT-X-VERSION:10
                #EXT-X-TARGETDURATION:2
                #EXT-X-PART-INF:PART-TARGET=1
                #EXT-X-SERVER-CONTROL:PART-HOLD-BACK=2
                \(declarations)
                #EXT-X-MAP:URI="init.mp4"
                #EXT-X-PART:DURATION=1,URI="part.m4s",INDEPENDENT=YES
                #EXT-X-PRELOAD-HINT:TYPE=PART,URI="next.m4s"
                """,
                relativeTo: sourceURL
            )
            let lowLatency = try #require(playlist.lowLatency)
            let contexts = [
                lowLatency.initializationMaps.first?.context,
                lowLatency.partialSegments.first?.resourceContext,
                lowLatency.preloadHints.first?.resourceContext,
            ]

            for context in contexts {
                let encryption = try #require(context?.encryption)
                #expect(encryption.method == "AES-128")
                #expect(encryption.keyURL == keyURL)
                #expect(encryption.keyFormat == "identity")
                #expect(encryption.keyFormatVersions == [1])
                #expect(
                    encryption.initializationVector
                        == Data(repeating: 0, count: 15) + Data([1])
                )
            }
        }
    }

    @Test("LL-HLS contexts retain encryption at each resource boundary")
    func retainsEncryptionAtResourceBoundaries() throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/live/main.m3u8")
        )
        let playlist = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-VERSION:10
            #EXT-X-TARGETDURATION:2
            #EXT-X-PART-INF:PART-TARGET=1
            #EXT-X-SERVER-CONTROL:PART-HOLD-BACK=2
            #EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://asset",KEYFORMAT="com.apple.streamingkeydelivery"
            #EXT-X-MAP:URI="init.mp4"
            #EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x1
            #EXT-X-PART:DURATION=1,URI="part.m4s",INDEPENDENT=YES
            """,
            relativeTo: sourceURL
        )
        let lowLatency = try #require(playlist.lowLatency)
        let mapEncryption = try #require(
            lowLatency.initializationMaps.first?.context.encryption
        )
        let partEncryption = try #require(
            lowLatency.partialSegments.first?.resourceContext?
                .encryption
        )

        #expect(mapEncryption.method == "SAMPLE-AES")
        #expect(
            mapEncryption.keyFormat
                == "com.apple.streamingkeydelivery"
        )
        #expect(partEncryption.method == "AES-128")
        #expect(partEncryption.keyFormat == "identity")
    }

    @Test("METHOD NONE clears every LL-HLS key format")
    func clearsParallelKeyFormatsFromResourceContexts() throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/live/main.m3u8")
        )
        let playlist = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-VERSION:10
            #EXT-X-TARGETDURATION:2
            #EXT-X-PART-INF:PART-TARGET=1
            #EXT-X-SERVER-CONTROL:PART-HOLD-BACK=2
            #EXT-X-KEY:METHOD=AES-128,URI="key.bin"
            #EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://asset",KEYFORMAT="com.apple.streamingkeydelivery"
            #EXT-X-KEY:METHOD=NONE
            #EXT-X-PART:DURATION=1,URI="part.m4s",INDEPENDENT=YES
            #EXT-X-PRELOAD-HINT:TYPE=PART,URI="next.m4s"
            """,
            relativeTo: sourceURL
        )
        let lowLatency = try #require(playlist.lowLatency)

        #expect(
            lowLatency.partialSegments.first?.resourceContext?
                .encryption == nil
        )
        #expect(
            lowLatency.preloadHints.first?.resourceContext?
                .encryption == nil
        )
    }

    @Test("MAP context resolves an implicit range like the media parser")
    func resolvesImplicitMapRangeFromPreviousSegment() throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/live/main.m3u8")
        )

        let playlist = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-VERSION:10
            #EXT-X-TARGETDURATION:1
            #EXT-X-PART-INF:PART-TARGET=1
            #EXT-X-SERVER-CONTROL:PART-HOLD-BACK=2
            #EXT-X-BYTERANGE:4@0
            #EXTINF:1,
            shared.bin
            #EXT-X-MAP:URI="shared.bin",BYTERANGE="4"
            #EXT-X-PART:DURATION=1,URI="1.0.m4s",INDEPENDENT=YES
            """,
            relativeTo: sourceURL
        )
        let map = try #require(
            playlist.lowLatency?.initializationMaps.first
        )

        #expect(map.resource.byteRange?.offset == 4)
        #expect(map.resource.byteRange?.length == 4)
    }

    @Test("a discontinuity must precede an edge PART to remain pending")
    func validatesPendingPartDiscontinuity() throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/live/main.m3u8")
        )

        #expect(throws: HLSDownloadError.invalidPlaylist) {
            try PlaylistResolver().resolve(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:2
                #EXT-X-PART-INF:PART-TARGET=1
                #EXT-X-SERVER-CONTROL:PART-HOLD-BACK=2
                #EXT-X-PART:DURATION=1,URI="10.0.ts",INDEPENDENT=YES
                #EXT-X-DISCONTINUITY
                """,
                relativeTo: sourceURL
            )
        }
        let playlist = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-TARGETDURATION:2
            #EXT-X-PART-INF:PART-TARGET=1
            #EXT-X-SERVER-CONTROL:PART-HOLD-BACK=2
            #EXT-X-DISCONTINUITY
            #EXT-X-PART:DURATION=1,URI="10.0.ts",INDEPENDENT=YES
            """,
            relativeTo: sourceURL
        )

        #expect(
            playlist.lowLatency?.partialSegments.first?
                .resourceContext?.discontinuitySequence == 1
        )
    }

    @Test("unknown preload-hint types are ignored")
    func ignoresUnknownPreloadHintTypes() throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/live/main.m3u8")
        )

        let playlist = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-PRELOAD-HINT:TYPE=FUTURE,URI="future.bin",DATE-OF-FIRST-USE="not-a-date"
            """,
            relativeTo: sourceURL
        )

        #expect(playlist.lowLatency?.preloadHints.isEmpty == true)
    }

    @Test(
        "invalid decryption-key preload contracts are rejected",
        arguments: [
            #"TYPE=KEY,URI="key.bin""#,
            #"TYPE=KEY,URI="key.bin",METHOD="AES-128""#,
            #"TYPE=KEY,URI="key.bin",METHOD=NONE"#,
            #"TYPE=KEY,URI="key.bin",METHOD=AES-128,KEYFORMAT="""#,
            #"TYPE=KEY,URI="key.bin",METHOD=AES-128,KEYFORMATVERSIONS="0""#,
            #"TYPE=KEY,URI="key.bin",METHOD=AES-128,DATE-OF-FIRST-USE=2026-08-06T12:00:08Z"#,
            #"TYPE=KEY,URI="key.bin",METHOD=AES-128,DATE-OF-FIRST-USE="not-a-date""#,
            #"TYPE=PART,URI="part.m4s",METHOD=AES-128"#,
        ]
    )
    func rejectsInvalidEncryptionKeyPreloadHints(
        attributes: String
    ) throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/live/main.m3u8")
        )

        #expect(throws: HLSDownloadError.invalidPlaylist) {
            try PlaylistResolver().resolve(
                """
                #EXTM3U
                #EXT-X-VERSION:5
                #EXT-X-TARGETDURATION:1
                #EXT-X-PART-INF:PART-TARGET=1
                #EXT-X-SERVER-CONTROL:PART-HOLD-BACK=2
                #EXT-X-PRELOAD-HINT:\(attributes)
                """,
                relativeTo: sourceURL
            )
        }
    }

    @Test("rendition reports do not block complete single-file media")
    func renditionReportIsOfflineScoped() throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/vod.m3u8")
        )

        let inspection = PlaylistResolver().inspect(
            """
            #EXTM3U
            #EXT-X-VERSION:9
            #EXT-X-RENDITION-REPORT:URI="alternate.m3u8",LAST-MSN=1
            #EXTINF:1,
            segment.ts
            #EXT-X-ENDLIST
            """,
            relativeTo: sourceURL
        )

        #expect(inspection.isValid)
        #expect(inspection.canDownloadAsSingleFile)
        #expect(!inspection.canCreateOfflinePackage)
        #expect(
            inspection.diagnostics == [
                HLSPlaylistDiagnostic(
                    severity: .error,
                    scope: .offlinePackage,
                    code: .mediaFeatureUnsupported,
                    lineNumber: 3,
                    mediaFeature: .renditionReportResource
                )
            ]
        )
    }

    @Test("server control alone remains advisory")
    func serverControlDoesNotBlockVOD() throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/vod.m3u8")
        )

        let inspection = PlaylistResolver().inspect(
            """
            #EXTM3U
            #EXT-X-VERSION:9
            #EXT-X-TARGETDURATION:4
            #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,HOLD-BACK=12
            #EXTINF:4,
            segment.ts
            #EXT-X-ENDLIST
            """,
            relativeTo: sourceURL
        )

        #expect(inspection.isValid)
        #expect(inspection.canDownloadAsSingleFile)
        #expect(inspection.canCreateOfflinePackage)
        #expect(inspection.playlist?.lowLatency != nil)
        #expect(inspection.diagnostics.isEmpty)
    }

    @Test(
        "invalid LL-HLS relationships are rejected",
        arguments: [
            """
            #EXTM3U
            #EXT-X-VERSION:8
            #EXT-X-SKIP:SKIPPED-SEGMENTS=1
            #EXTINF:1,
            segment.ts
            #EXT-X-ENDLIST
            """,
            """
            #EXTM3U
            #EXT-X-PART-INF:PART-TARGET=1
            #EXTINF:1,
            segment.ts
            #EXT-X-ENDLIST
            """,
            """
            #EXTM3U
            #EXT-X-VERSION:9
            #EXT-X-PART-INF:PART-TARGET=1
            #EXT-X-SERVER-CONTROL:PART-HOLD-BACK=2
            #EXT-X-PART:DURATION=1,URI="one.ts",BYTERANGE="100@0"
            #EXT-X-PART:DURATION=1,URI="two.ts",BYTERANGE="100@0"
            #EXT-X-PART:DURATION=1,URI="one.ts",BYTERANGE="100"
            #EXTINF:1,
            segment.ts
            #EXT-X-ENDLIST
            """,
            """
            #EXTM3U
            #EXT-X-VERSION:9
            #EXT-X-PART:DURATION=1,URI="part.ts"
            #EXTINF:1,
            segment.ts
            #EXT-X-ENDLIST
            """,
            """
            #EXTM3U
            #EXT-X-VERSION:9
            #EXT-X-PART-INF:PART-TARGET=1
            #EXT-X-SERVER-CONTROL:PART-HOLD-BACK=2
            #EXT-X-PART:DURATION=2,URI="part.ts"
            #EXTINF:2,
            segment.ts
            #EXT-X-ENDLIST
            """,
            """
            #EXTM3U
            #EXT-X-TARGETDURATION:4
            #EXT-X-SERVER-CONTROL:CAN-SKIP-UNTIL=23.9
            #EXTINF:4,
            segment.ts
            #EXT-X-ENDLIST
            """,
            """
            #EXTM3U
            #EXT-X-VERSION:9
            #EXT-X-TARGETDURATION:4
            #EXT-X-SERVER-CONTROL:HOLD-BACK=11
            #EXTINF:4,
            segment.ts
            #EXT-X-ENDLIST
            """,
            """
            #EXTM3U
            #EXT-X-VERSION:9
            #EXT-X-SERVER-CONTROL:CAN-SKIP-DATERANGES=YES
            #EXTINF:1,
            segment.ts
            #EXT-X-ENDLIST
            """,
            """
            #EXTM3U
            #EXT-X-VERSION:9
            #EXT-X-PART-INF:PART-TARGET=1
            #EXT-X-SERVER-CONTROL:PART-HOLD-BACK=2
            #EXT-X-PART:DURATION=1,URI="part.ts",BYTERANGE="100"
            #EXTINF:1,
            segment.ts
            #EXT-X-ENDLIST
            """,
            """
            #EXTM3U
            #EXT-X-VERSION:9
            #EXT-X-PART-INF:PART-TARGET=1
            #EXT-X-SERVER-CONTROL:PART-HOLD-BACK=2
            #EXT-X-PRELOAD-HINT:TYPE=PART,URI="one.ts"
            #EXTINF:1,
            segment.ts
            #EXT-X-ENDLIST
            """,
            """
            #EXTM3U
            #EXT-X-VERSION:9
            #EXT-X-RENDITION-REPORT:URI="https://media.example/alternate.m3u8",LAST-MSN=1
            #EXTINF:1,
            segment.ts
            #EXT-X-ENDLIST
            """,
            """
            #EXTM3U
            #EXT-X-VERSION:9
            #EXT-X-SKIP:SKIPPED-SEGMENTS=1,RECENTLY-REMOVED-DATERANGES="one"
            #EXTINF:1,
            segment.ts
            #EXT-X-ENDLIST
            """,
            """
            #EXTM3U
            #EXT-X-PART-INF:PART-TARGET=1
            #EXT-X-SERVER-CONTROL:PART-HOLD-BACK=2
            #EXT-X-PART:DURATION=0.5,URI="short.ts"
            #EXT-X-PART:DURATION=1,URI="regular.ts"
            #EXTINF:1.5,
            segment.ts
            #EXT-X-ENDLIST
            """,
            """
            #EXTM3U
            #EXT-X-VERSION:9
            #EXT-X-SKIP:RECENTLY-REMOVED-DATERANGES="one"
            #EXTINF:1,
            segment.ts
            #EXT-X-ENDLIST
            """,
        ]
    )
    func rejectsInvalidLowLatencyRelationships(
        source: String
    ) throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/live/main.m3u8")
        )

        #expect(throws: HLSDownloadError.invalidPlaylist) {
            try PlaylistResolver().resolve(
                source,
                relativeTo: sourceURL
            )
        }
    }
}
